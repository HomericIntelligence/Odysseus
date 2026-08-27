#!/usr/bin/env bash
set -euo pipefail

# This legacy diagnostic collapsed authentication, network, and API failures to
# JSON null and did not capture repository settings, rulesets, or restore-shape
# validation. It is not valid activation or rollback evidence.
echo "ERROR: legacy partial snapshotting is retired; use apply-repo-rulesets.sh dry-run/preflight snapshots" >&2
exit 2
