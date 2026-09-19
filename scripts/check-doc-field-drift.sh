#!/usr/bin/env bash
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
#   2  Usage or operational/unavailable failure.

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
#
# Capture the NUL-delimited inventory in a private temporary file so both Git's
# exit status and unusual tracked path bytes are preserved. Process-substitution
# status is not propagated by pipefail, while a shell variable cannot contain
# NUL bytes.
tracked_inventory="$(mktemp)" || {
  printf 'error: cannot allocate tracked-document inventory\n' >&2
  exit 2
}
# shellcheck disable=SC2329  # Invoked indirectly by the trap below.
cleanup() {
  rm -f -- "$tracked_inventory"
}
trap cleanup EXIT HUP INT TERM
if ! git ls-files -z -- '*.md' > "$tracked_inventory"; then
  printf 'error: git ls-files failed\n' >&2
  exit 2
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
python3 - "$tracked_inventory" "$REPO_ROOT" "$script_dir" <<'PY'
import os
import re
import sys
from pathlib import Path

inventory_path, root_text, script_dir = sys.argv[1:]
sys.path.insert(0, script_dir)
from tracked_scan import UnsafeTrackedPathError, read_regular_no_follow

excluded = (
    "infrastructure/", "control/", "provisioning/", "ci-cd/", "research/",
    "shared/", "testing/", ".github/",
)
pattern = re.compile(
    r"^[ \t]*-?[ \t]*(?:title|depends_on|['\"]title['\"]|"
    r"['\"]depends_on['\"])[ \t]*:"
)
found = False
scanned = 0
for encoded in Path(inventory_path).read_bytes().split(b"\0"):
    if not encoded:
        continue
    relative = os.fsdecode(encoded)
    if relative.startswith(excluded):
        continue
    try:
        content = read_regular_no_follow(Path(root_text), relative)
    except (UnsafeTrackedPathError, OSError) as exc:
        print(f"error: document-field scan unavailable for {relative!r}: {exc}", file=sys.stderr)
        raise SystemExit(2)
    if content is None:
        continue
    scanned += 1
    for number, line in enumerate(content.decode("utf-8", errors="replace").splitlines(), 1):
        if pattern.search(line):
            print(f"{relative}:{number}:{line}")
            found = True
if not scanned:
    print("check-doc-field-drift: no first-party docs to scan")
# Keep content drift distinct from Python/import/inventory failures, which
# conventionally exit 1 and must be reported as unavailable rather than as a
# false policy finding.
raise SystemExit(3 if found else 0)
PY
scan_status=$?
case "$scan_status" in
  0)
    echo "check-doc-field-drift: OK — no deprecated workflow field names in first-party docs"
    exit 0
    ;;
  3)
    echo "ERROR: deprecated workflow field name(s) found in first-party docs." >&2
    echo "Use 'subject' instead of 'title' and 'blocked_by' instead of 'depends_on'." >&2
    exit 1
    ;;
  *)
    printf 'error: document-field scan failed or was unavailable\n' >&2
    exit 2
    ;;
esac
