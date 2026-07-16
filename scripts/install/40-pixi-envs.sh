#!/usr/bin/env bash
# Phase 40 — Pixi Environments
#
# Runs `pixi install` at the Odysseus root, then for each submodule that has
# a pixi.toml. Only installs default features (no --feature dev).
# Idempotent: pixi install is safe to run repeatedly.
#
# ADR-015 forward-compatibility: PIXI_DIRS below is the canonical pre-rename
# list (each entry reflects the repo name as it was when this script was
# last touched). `resolve_submodule_path` (from lib.sh) may flip an entry
# from `Project<X>` to `<X>` on disk after the upstream `gh repo rename`
# lands; when this happens we surface `↻ ADR-015 dual-path: …` in the
# install log so operators can see both the list name and the actual
# on-disk path used.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Pixi Environments"

if ! has_cmd pixi; then
    # pixi is provisioned by phase 20 (Hephaestus). During Phase-1 detect
    # (which sources this script before phase 20 has run) pixi is legitimately
    # absent, so this is a WARN, not a hard fail: it flags the phase for install
    # without counting toward the exit gate. On the real install pass phase 20
    # runs first, pixi is on PATH, and this branch is not taken. If pixi is
    # somehow still missing at real-install time, the downstream pixi env checks
    # surface it — see issue #393.
    check_warn "pixi not found — will be installed by phase 20 (Hephaestus)"
    return 0 2>/dev/null || exit 0
fi

check_pass "pixi $(pixi --version 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1)"

# All directories (relative to ODYSSEUS_ROOT) that contain pixi.toml
PIXI_DIRS=(
    "."
    "ci-cd/Proteus"
    "control/Agamemnon"
    "control/Nestor"
    "infrastructure/AchaeanFleet"
    "infrastructure/Argus"
    "infrastructure/Hermes"
    "provisioning/Myrmidons"
    "provisioning/Keystone"
    "provisioning/Telemachy"
    "research/Odyssey"
    "research/Scylla"
    "shared/Hephaestus"
    "shared/Mnemosyne"
    "testing/Charybdis"
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

# Per ADR-015: PIXI_DIRS may mix prefixed (`Project<X>`) entries with bare
# (`<X>`) entries, depending on whether each repo's upstream `gh repo rename`
# has happened. `resolve_submodule_path` (from lib.sh) prefers the input form
# and falls back to the bare name when the prefixed form is absent on disk,
# so each repo's path resolves correctly in either world. When the resolver
# swaps the form, we surface it in the install log so operators can see the
# forward-compatible behaviour kicking in.
for dir in "${PIXI_DIRS[@]}"; do
    resolved=$(resolve_submodule_path "$dir")
    if [[ "$resolved" != "$dir" ]]; then
        echo -e "    ${DIM}↻ ADR-015 dual-path: $dir → $resolved${NC}"
    fi
    pixi_install_dir "$resolved"
done
