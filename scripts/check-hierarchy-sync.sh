#!/usr/bin/env bash
#
# check-hierarchy-sync.sh — Validate per-repo HMAS hierarchy copies against
# the canonical set in provisioning/Myrmidons/agents/hierarchy/.
#
# Per ADR-020 §5 and Odysseus issue #467, Myrmidons is the GitOps source of
# truth for the mesh-wide 6-level agent hierarchy. Repos that carry a copy of
# the definitions (currently research/Odyssey/.claude/agents/) must stay in
# identity-tuple sync with the canonical set. The identity tuple is:
#
#   name, level, phase, tools, model, delegates_to, receives_from
#
# Usage:
#   check-hierarchy-sync.sh            Print a human-readable report.
#   check-hierarchy-sync.sh --ci       Machine-friendly summary only.
#
# Environment:
#   ODYSSEUS_STRICT_SYNC=1  Fail (exit 2) when a submodule working tree is not
#                           initialized instead of skipping with a notice.
#                           Defeats silent vacuous passes in CI.
#
# Exit codes:
#   0  In sync (or skipped because a submodule is not initialized / the
#      canonical set is not yet present at the pinned SHA).
#   1  Drift detected — one or more copies are missing or diverged.
#   2  Environment error (bad arguments, strict mode with missing trees).
#
# Used by `just check-hierarchy-sync`.

set -uo pipefail

CI_MODE=0
case "${1:-}" in
  "")        ;;
  --ci)      CI_MODE=1 ;;
  -h|--help)
    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

STRICT="${ODYSSEUS_STRICT_SYNC:-0}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 2
}
cd "$REPO_ROOT" || exit 2

CANONICAL_DIR="$REPO_ROOT/provisioning/Myrmidons/agents/hierarchy"

# Sync targets: source directories whose *.md definitions must match the
# canonical set. Extend this list as more repos adopt hierarchy copies.
SYNC_TARGETS=(
  "$REPO_ROOT/research/Odyssey/.claude/agents"
)

# Frontmatter identity-tuple fields compared between copies.
IDENTITY_FIELDS=(name level phase tools model delegates_to receives_from)

drift_count=0
notice_count=0

# Print a field from an agent file's frontmatter (first match, empty if absent).
frontmatter_field() {
  local file="$1" field="$2"
  awk -v f="$field" '
    NR == 1 && $0 !~ /^---[[:space:]]*$/ { exit }
    NR > 1 && /^---[[:space:]]*$/        { exit }
    $0 ~ "^" f ":" { sub("^" f ":[[:space:]]*", ""); print; exit }
  ' "$file"
}

if [ ! -d "$CANONICAL_DIR" ]; then
  msg="provisioning/Myrmidons not initialized or agents/hierarchy/ absent at pinned SHA — skipping (canonical set not yet pinned)"
  printf 'notice: %s\n' "$msg"
  if [ "$STRICT" = "1" ]; then
    printf 'error: ODYSSEUS_STRICT_SYNC=1 and canonical hierarchy directory is missing: %s\n' "$CANONICAL_DIR" >&2
    exit 2
  fi
  exit 0
fi

for target in "${SYNC_TARGETS[@]}"; do
  target_name="${target#"$REPO_ROOT"/}"
  if [ ! -d "$target" ]; then
    msg="sync source $target_name not initialized — skipping"
    printf 'notice: %s\n' "$msg"
    notice_count=$((notice_count + 1))
    if [ "$STRICT" = "1" ]; then
      printf 'error: ODYSSEUS_STRICT_SYNC=1 and sync source is missing: %s\n' "$target" >&2
      exit 2
    fi
    continue
  fi

  printf '## Hierarchy sync: %s vs provisioning/Myrmidons/agents/hierarchy/\n\n' "$target_name"

  # Index canonical definitions by frontmatter name.
  declare -A canon_file=()
  canon_count=0
  for canon_md in "$CANONICAL_DIR"/*.md; do
    [ "$(basename "$canon_md")" = "README.md" ] && continue
    cname="$(frontmatter_field "$canon_md" name)"
    if [ -n "$cname" ]; then
      canon_file["$cname"]="$canon_md"
      canon_count=$((canon_count + 1))
    fi
  done

  # Index source definitions by frontmatter name (detect duplicates).
  declare -A src_file=()
  for src_md in "$target"/*.md; do
    [ -e "$src_md" ] || continue
    [ "$(basename "$src_md")" = "README.md" ] && continue
    sname="$(frontmatter_field "$src_md" name)"
    if [ -z "$sname" ]; then
      printf 'DRIFT %s: no frontmatter name found\n' "${src_md#"$REPO_ROOT"/}"
      drift_count=$((drift_count + 1))
      continue
    fi
    if [ -n "${src_file["$sname"]:-}" ]; then
      printf 'DRIFT duplicate frontmatter name %s in %s\n' "$sname" "$target_name"
      drift_count=$((drift_count + 1))
    fi
    src_file["$sname"]="$src_md"
  done

  # Forward check: every source definition must exist in the canonical set
  # with an identical identity tuple.
  for sname in "${!src_file[@]}"; do
    src_md="${src_file["$sname"]}"
    if [ -z "${canon_file["$sname"]:-}" ]; then
      printf 'DRIFT %s: agent %s missing from canonical set\n' \
        "${src_md#"$REPO_ROOT"/}" "$sname"
      drift_count=$((drift_count + 1))
      continue
    fi
    canon_md="${canon_file["$sname"]}"
    for field in "${IDENTITY_FIELDS[@]}"; do
      sval="$(frontmatter_field "$src_md" "$field")"
      cval="$(frontmatter_field "$canon_md" "$field")"
      if [ "$sval" != "$cval" ]; then
        printf 'DRIFT %s: %s differs (source: %q canonical: %q)\n' \
          "$sname" "$field" "$sval" "$cval"
        drift_count=$((drift_count + 1))
      fi
    done
  done

  # Reverse check: canonical definitions absent from this source are reported
  # as notices, not drift — repos may legitimately adopt a subset.
  for cname in "${!canon_file[@]}"; do
    if [ -z "${src_file["$cname"]:-}" ]; then
      printf 'notice: canonical agent %s not present in %s (subset adoption is allowed)\n' \
        "$cname" "$target_name"
      notice_count=$((notice_count + 1))
    fi
  done
  unset canon_file src_file

  printf '\n'
done

if [ "$CI_MODE" -eq 1 ]; then
  printf 'hierarchy_drift=%s\n' "$([ "$drift_count" -gt 0 ] && printf true || printf false)"
  printf 'hierarchy_notices=%d\n' "$notice_count"
else
  if [ "$drift_count" -eq 0 ]; then
    printf 'Hierarchy sync OK (%d notice(s)).\n' "$notice_count"
  else
    printf 'Hierarchy sync FAILED: %d drift item(s).\n' "$drift_count" >&2
  fi
fi

if [ "$drift_count" -gt 0 ]; then
  exit 1
fi
exit 0
