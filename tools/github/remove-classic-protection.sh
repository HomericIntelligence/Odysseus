#!/usr/bin/env bash
set -euo pipefail

# This legacy path deleted protection without a validated full restore snapshot,
# equivalent active-ruleset readback, exact 404 verification, or compensating
# rollback. Classic protection is now migrated only inside the scoped repository
# reconciler transaction.
echo "ERROR: direct classic-protection removal is retired; use apply-repo-rulesets.sh with reviewed activation evidence" >&2
exit 2
