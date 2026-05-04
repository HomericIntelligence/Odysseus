#!/usr/bin/env bash
# Phase 95 — Documentation Tools
#
# For research repos that declare a [feature.docs] section or mkdocs in
# pixi.toml, runs `pixi install --feature docs` to make docs tooling available.
#
# Failures are warnings — docs tooling is optional for non-docs contributors.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "Documentation Tools"

if ! has_cmd pixi; then
    check_fail "pixi not found — install it first (production install phase 20)"
    return 0 2>/dev/null || exit 0
fi

# Repos expected to have docs tooling (mkdocs, sphinx, etc.)
DOCS_REPOS=(
    "research/ProjectOdyssey"
    "research/ProjectScylla"
)

for repo in "${DOCS_REPOS[@]}"; do
    dir="$ODYSSEUS_ROOT/$repo"
    pixi_toml="$dir/pixi.toml"

    if [[ ! -f "$pixi_toml" ]]; then
        check_skip "$repo — no pixi.toml (skipped)"
        continue
    fi

    # Check for [feature.docs] or mkdocs reference
    if ! grep -qE 'feature\.docs|feature\."docs"|mkdocs|\[feature\.docs' "$pixi_toml" 2>/dev/null; then
        check_skip "$repo — no [feature.docs] or mkdocs in pixi.toml (skipped)"
        continue
    fi

    if [[ "${INSTALL:-false}" != "true" ]]; then
        if [[ -d "$dir/.pixi/envs/docs" ]]; then
            check_pass "$repo — docs env present"
        else
            check_warn "$repo — docs env not initialized (run with --install)"
        fi
        continue
    fi

    echo -e "    ${BLUE}→${NC} pixi install --feature docs: $repo"
    if (cd "$dir" && pixi install -q --feature docs 2>/dev/null); then
        check_pass "$repo — docs deps installed"
    else
        check_warn "$repo — docs deps skipped (feature may not exist in this version)"
    fi
done
