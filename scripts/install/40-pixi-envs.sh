#!/usr/bin/env bash
# Phase 40 — Pixi Environments
#
# Runs `pixi install` at the Odysseus root, then for each submodule that has
# a pixi.toml. Only installs default features (no --feature dev).
# Idempotent: pixi install is safe to run repeatedly.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Pixi Environments"

if ! has_cmd pixi; then
    check_fail "pixi not found — install it first (phase 20 / ProjectHephaestus installer)"
    return 0 2>/dev/null || exit 0
fi

check_pass "pixi $(pixi --version 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1)"

# All directories (relative to ODYSSEUS_ROOT) that contain pixi.toml
PIXI_DIRS=(
    "."
    "ci-cd/ProjectProteus"
    "control/ProjectAgamemnon"
    "control/ProjectNestor"
    "infrastructure/AchaeanFleet"
    "infrastructure/ProjectArgus"
    "infrastructure/ProjectHermes"
    "provisioning/Myrmidons"
    "provisioning/ProjectKeystone"
    "provisioning/ProjectTelemachy"
    "research/ProjectOdyssey"
    "research/ProjectScylla"
    "shared/ProjectHephaestus"
    "shared/ProjectMnemosyne"
    "testing/ProjectCharybdis"
)

pixi_install_dir() {
    local dir="$1"
    local abs_dir="$ODYSSEUS_ROOT/$dir"
    local label="${dir:-.}"
    [[ "$dir" == "." ]] && label="Odysseus root"

    if [[ ! -f "$abs_dir/pixi.toml" ]]; then
        check_skip "$label — no pixi.toml (skipped)"
        return 0
    fi

    if [[ "${INSTALL:-false}" != "true" ]]; then
        # Check-only: verify .pixi/envs/default exists as proxy for "installed"
        if [[ -d "$abs_dir/.pixi/envs/default" ]]; then
            check_pass "$label — pixi env present"
        else
            check_warn "$label — pixi env not initialized (run with --install)"
        fi
        return 0
    fi

    echo -e "    ${BLUE}→${NC} pixi install: $label"
    if (cd "$abs_dir" && pixi install -q 2>&1); then
        check_pass "$label — pixi env installed"
    else
        check_warn "$label — pixi install failed (non-fatal; may require network access)"
    fi
}

for dir in "${PIXI_DIRS[@]}"; do
    pixi_install_dir "$dir"
done
