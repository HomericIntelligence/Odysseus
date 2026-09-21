#!/bin/sh
#
# check-doc-field-drift.sh — Guard Odysseus first-party docs against
# deprecated workflow-schema field names (issue #25).
#
# Canonical field names come from the Telemachy Pydantic models
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

set -u

case "${1:-}" in
  "") ;;
  -h|--help)
    printf '%s\n' \
      'Usage: check-doc-field-drift.sh [-h|--help]' \
      'Check exact staged first-party Markdown blobs for deprecated workflow keys.'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

case "$0" in
  /*) script_path=$0 ;;
  *) script_path=$PWD/$0 ;;
esac
script_directory=${script_path%/*}
if [ "$script_directory" = "$script_path" ]; then
  script_directory=.
fi
unset CDPATH
repo_root=$(command cd -P -- "$script_directory/.." && command pwd -P) || {
  printf 'error: could not bind the repository directory\n' >&2
  exit 2
}
unset BASH_ENV ENV GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
exec /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
  /usr/bin/python3 -I -S "$repo_root/scripts/check_doc_field_drift.py" \
  --repo-root "$repo_root"
