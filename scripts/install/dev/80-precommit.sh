#!/usr/bin/env bash
# Phase 80 — Pre-commit Hook Installation
#
# Finds every .pre-commit-config.yaml within the Odysseus tree (max depth 3)
# and runs `pre-commit install` in that directory.
#
# Failures are warnings — a missing hook is inconvenient but not fatal.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "Pre-commit Hooks"

if ! has_cmd pre-commit; then
    check_fail "pre-commit not found — install it first (pip install pre-commit)"
    return 0 2>/dev/null || exit 0
fi

check_pass "pre-commit $(pre-commit --version 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1)"

# Find all pre-commit config files
mapfile -t CONFIGS < <(find "$ODYSSEUS_ROOT" -maxdepth 3 -name ".pre-commit-config.yaml" 2>/dev/null | sort)

if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    check_warn "No .pre-commit-config.yaml files found under $ODYSSEUS_ROOT"
    return 0 2>/dev/null || exit 0
fi

for cfg in "${CONFIGS[@]}"; do
    repo_dir="$(dirname "$cfg")"
    label="${repo_dir#"$ODYSSEUS_ROOT/"}"
    [[ "$label" == "$ODYSSEUS_ROOT" ]] && label="."

    if [[ "${INSTALL:-false}" != "true" ]]; then
        # Check-only: verify .git/hooks/pre-commit exists
        if [[ -f "$repo_dir/.git/hooks/pre-commit" ]]; then
            check_pass "pre-commit: $label — hooks installed"
        else
            check_warn "pre-commit: $label — hooks not installed (run with --install)"
        fi
        continue
    fi

    echo -e "    ${BLUE}→${NC} pre-commit install: $label"
    if (cd "$repo_dir" && pre-commit install --install-hooks >/dev/null 2>&1); then
        check_pass "pre-commit: $label — hooks installed"
    else
        check_warn "pre-commit install failed: $label (non-fatal)"
    fi
done
