#!/usr/bin/env bash
#
# check-doc-field-drift.sh — Guard Odysseus first-party docs against
# deprecated workflow-schema field names (issue #25).
#
# Canonical field names come from the ProjectTelemachy Pydantic models
# (src/telemachy/models.py TaskSpec) and the Agamemnon REST payload
# (agamemnon_client.py):
#   YAML field   wire form          deprecated (do NOT use)
#   subject      subject            title
#   blocked_by   blockedBy          depends_on
#   assign_to    assigneeAgentId    (none — assign_to is current)
#
# This guards ONLY first-party Odysseus docs. Submodules under infrastructure/
# control/ provisioning/ ci-cd/ research/ shared/ testing/ are owned by their
# own repos and are not scanned.
#
# Usage:
#   check-doc-field-drift.sh           Run the check.
#   check-doc-field-drift.sh -h|--help Print this help and exit.
#
# Exit codes:
#   0  No deprecated workflow field names found.
#   1  Drift detected — a deprecated field name appears in a guarded doc.
#   2  Usage error.

set -uo pipefail

case "${1:-}" in
  "") ;;
  -h|--help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 2
}
cd "$REPO_ROOT" || exit 2

# First-party markdown docs only; never scan submodule trees or GitHub templates
# (.github/ISSUE_TEMPLATE uses YAML frontmatter with a 'title:' key that is not
# a workflow field — exclude to avoid false positives).
mapfile -t docs < <(
  git ls-files -- '*.md' \
    | awk '!/^(infrastructure|control|provisioning|ci-cd|research|shared|testing|\.github)\//'
)

if (( ${#docs[@]} == 0 )); then
  echo "check-doc-field-drift: no first-party docs to scan"
  exit 0
fi

# Match deprecated names only as workflow-schema field keys
# (e.g. "title:" / "depends_on:" in a YAML task block), so prose and
# PR-title guidance are not false-positives.
pattern='^[[:space:]]*-?[[:space:]]*(title|depends_on):'

if grep -nE "$pattern" "${docs[@]}"; then
  echo "ERROR: deprecated workflow field name(s) found in first-party docs." >&2
  echo "Use 'subject' instead of 'title' and 'blocked_by' instead of 'depends_on'." >&2
  exit 1
fi

echo "check-doc-field-drift: OK — no deprecated workflow field names in first-party docs"
exit 0
