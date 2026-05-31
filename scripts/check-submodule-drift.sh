#!/usr/bin/env bash
#
# check-submodule-drift.sh — Detect when Odysseus submodule pins have fallen
# behind their upstream default branch.
#
# Each submodule in Odysseus is pinned to a specific SHA representing the last
# known-good cross-repo integration point. Over time these pins go stale. This
# script compares each pinned SHA against the upstream default-branch HEAD and
# reports which submodules are behind.
#
# Usage:
#   check-submodule-drift.sh           Print a human-readable table.
#   check-submodule-drift.sh --ci      Also write drift-report.json and emit
#                                      has_drift=<bool> to $GITHUB_OUTPUT.
#
# Exit codes:
#   0  No drift — all submodule pins match their upstream default branch.
#   1  Drift detected — one or more submodules are behind.
#   2  Usage or environment error (network failure, bad arguments, etc.).
#
# Used by both the GitHub Actions workflow and `just check-submodule-drift`.

set -uo pipefail

CI_MODE=0
case "${1:-}" in
  "")        ;;
  --ci)      CI_MODE=1 ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

# Resolve the repository root so the script works from any cwd.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 2
}
cd "$REPO_ROOT" || exit 2

GITMODULES="$REPO_ROOT/.gitmodules"
if [ ! -f "$GITMODULES" ]; then
  printf 'error: %s not found\n' "$GITMODULES" >&2
  exit 2
fi

# Enumerate submodule logical names from .gitmodules.
mapfile -t SUBMODULES < <(
  git config --file "$GITMODULES" --get-regexp 'submodule\..*\.path' \
    | sed -E 's/^submodule\.(.*)\.path .*/\1/'
)

if [ "${#SUBMODULES[@]}" -eq 0 ]; then
  printf 'error: no submodules found in .gitmodules\n' >&2
  exit 2
fi

drift_count=0
error_count=0
json_rows=()

printf '## Submodule Drift Report\n\n'
printf '| Submodule | Pinned SHA | Upstream SHA | Behind By | Last Updated |\n'
printf '|-----------|-----------|--------------|-----------|--------------|\n'

for name in "${SUBMODULES[@]}"; do
  path="$(git config --file "$GITMODULES" --get "submodule.${name}.path")"
  url="$(git config --file "$GITMODULES" --get "submodule.${name}.url")"

  # Pinned SHA = the gitlink recorded in the Odysseus tree for this path.
  pinned="$(git ls-tree HEAD "$path" 2>/dev/null | awk '{print $3}')"
  if [ -z "$pinned" ]; then
    printf '| %s | (unpinned) | - | - | - |\n' "$path"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"no gitlink"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  # Determine the upstream default branch HEAD via ls-remote.
  remote_head="$(git ls-remote --symref "$url" HEAD 2>/dev/null | awk '/^ref:/ {print $2}')"
  if [ -z "$remote_head" ]; then
    printf '| %s | %s | (unreachable) | - | - |\n' "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"remote unreachable"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  upstream="$(git ls-remote "$url" "$remote_head" 2>/dev/null | awk '{print $1}')"
  if [ -z "$upstream" ]; then
    printf '| %s | %s | (unreachable) | - | - |\n' "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"remote unreachable"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  if [ "$pinned" = "$upstream" ]; then
    printf '| %s | %s | %s | up to date | - |\n' "$path" "${pinned:0:8}" "${upstream:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"current","pinned":"%s","upstream":"%s"}' "$path" "$pinned" "$upstream")")
    continue
  fi

  # Drift detected. Try to count commits behind and the upstream commit date by
  # fetching into the local submodule clone if present; otherwise report unknown.
  behind="?"
  last_updated="unknown"
  if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
    # Best-effort fetch (Bucket B, no-silent-failures.md): the drift count and
    # date below are optional enrichment — if the network is unavailable the
    # rev-list/show steps fall back to "?"/"unknown", so a fetch failure is not
    # fatal. Surface it as a warning rather than swallowing the exit code.
    if ! git -C "$path" fetch --quiet "$url" "$remote_head" 2>/dev/null; then
      printf 'warn: best-effort fetch failed for %s (drift detail may be incomplete)\n' "$path" >&2
    fi
    count="$(git -C "$path" rev-list --count "${pinned}..${upstream}" 2>/dev/null || echo "")"
    [ -n "$count" ] && behind="$count"
    date_str="$(git -C "$path" show -s --format=%cs "$upstream" 2>/dev/null || echo "")"
    [ -n "$date_str" ] && last_updated="$date_str"
  fi

  printf '| %s | %s | %s | %s commits | %s |\n' \
    "$path" "${pinned:0:8}" "${upstream:0:8}" "$behind" "$last_updated"
  json_rows+=("$(printf '{"submodule":"%s","status":"behind","pinned":"%s","upstream":"%s","behind":"%s","last_updated":"%s"}' \
    "$path" "$pinned" "$upstream" "$behind" "$last_updated")")
  drift_count=$((drift_count + 1))
done

printf '\n'
if [ "$drift_count" -eq 0 ] && [ "$error_count" -eq 0 ]; then
  printf '**All %d submodule pins are up to date.**\n' "${#SUBMODULES[@]}"
else
  printf '**%d submodule(s) behind upstream; %d error(s).**\n' "$drift_count" "$error_count"
fi

if [ "$CI_MODE" -eq 1 ]; then
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "drift_count": %d,\n' "$drift_count"
    printf '  "error_count": %d,\n' "$error_count"
    printf '  "submodules": [\n'
    for i in "${!json_rows[@]}"; do
      sep=","
      [ "$i" -eq $((${#json_rows[@]} - 1)) ] && sep=""
      printf '    %s%s\n' "${json_rows[$i]}" "$sep"
    done
    printf '  ]\n'
    printf '}\n'
  } > drift-report.json

  has_drift="false"
  [ "$drift_count" -gt 0 ] && has_drift="true"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'has_drift=%s\n' "$has_drift" >> "$GITHUB_OUTPUT"
  else
    printf 'has_drift=%s\n' "$has_drift"
  fi
fi

# Network errors take precedence so CI fails visibly rather than silently.
if [ "$error_count" -gt 0 ]; then
  exit 2
fi
if [ "$drift_count" -gt 0 ]; then
  exit 1
fi
exit 0
