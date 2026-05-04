#!/usr/bin/env bash
# Phase 70 — Dev Python Dependencies
#
# For each Python repo that declares a [feature.dev] section in its pixi.toml,
# runs `pixi install --feature dev` to install development extras (pytest, ruff,
# mypy, etc.).
#
# Failures are warnings — partial dev env is acceptable.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "Python Dev Dependencies"

if ! has_cmd pixi; then
    check_fail "pixi not found — install it first (production install phase 20)"
    return 0 2>/dev/null || exit 0
fi

# Repos that are expected to have [feature.dev] in pixi.toml
PYTHON_REPOS=(
    "infrastructure/ProjectHermes"
    "infrastructure/ProjectArgus"
    "provisioning/ProjectTelemachy"
    "provisioning/ProjectKeystone"
    "research/ProjectScylla"
    "shared/ProjectHephaestus"
    "research/ProjectOdyssey"
    "testing/ProjectCharybdis"
)

for repo in "${PYTHON_REPOS[@]}"; do
    dir="$ODYSSEUS_ROOT/$repo"
    pixi_toml="$dir/pixi.toml"

    # Skip if no pixi.toml
    if [[ ! -f "$pixi_toml" ]]; then
        check_skip "$repo — no pixi.toml (skipped)"
        continue
    fi

    # Skip if no dev feature declared
    if ! grep -qE 'feature\.dev|feature\."dev"|\[feature\.dev' "$pixi_toml" 2>/dev/null; then
        check_skip "$repo — no [feature.dev] declared (skipped)"
        continue
    fi

    if [[ "${INSTALL:-false}" != "true" ]]; then
        # Check-only: verify dev env exists
        if [[ -d "$dir/.pixi/envs/dev" ]]; then
            check_pass "$repo — dev env present"
        else
            check_warn "$repo — dev env not initialized (run with --install)"
        fi
        continue
    fi

    echo -e "    ${BLUE}→${NC} pixi install --feature dev: $repo"
    if (cd "$dir" && pixi install -q --feature dev 2>&1); then
        check_pass "$repo — dev deps installed"
    else
        check_warn "$repo — dev deps failed (non-fatal; check $pixi_toml)"
    fi
done
