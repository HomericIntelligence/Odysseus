#!/usr/bin/env bash
set -euo pipefail

# The former organization-level ~ALL policy is intentionally retired. The
# organization contains an active fork which must never inherit first-party
# governance. Repository-owned baselines are selected from Odysseus plus its
# declared submodules by apply-repo-rulesets.sh.
echo "ERROR: organization-wide ruleset application is retired; use apply-repo-rulesets.sh" >&2
exit 2
