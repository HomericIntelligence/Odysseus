#!/usr/bin/env bash
# Phase 10 — System Dependencies
#
# Installs core system packages required by all subsequent phases.
# Idempotent: checks each package before attempting install.
# Non-fatal on non-Debian hosts (apt unavailable).
#
# shellcheck disable=SC2015
set -uo pipefail

# Source shared lib (sets ODYSSEUS_ROOT if not already set)
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "System Dependencies"

APT_PKGS=(
    git
    curl
    wget
    ca-certificates
    build-essential
    libssl-dev
    libssl3
    python3
    python3-pip
    pkg-config
    tmux
    skopeo
    unzip
    jq
)

# Detect whether apt-get is available
if ! has_cmd apt-get; then
    check_warn "apt-get not available — skipping system package installation (non-Debian host)"
    return 0 2>/dev/null || exit 0
fi

# Collect missing packages.
#
# A missing package is only a genuine FAILURE when we cannot fix it: in
# check-only mode (`--check`) or on a host without apt. During an actual
# `--install` run the correct terminal signal is the *post-install* outcome —
# not the pre-install "NOT FOUND", which every clean image trivially trips and
# which (once counted) is never retracted even after the package installs
# cleanly. So during --install we record missing packages WITHOUT calling
# check_fail, then judge by whether the batch apt-get install actually
# succeeds. This is the same "judge on outcome, not on initial absence"
# discipline the exit-gate (#372/#389) requires for a clean-image worker
# install to legitimately reach exit 0.
MISSING_PKGS=()
for pkg in "${APT_PKGS[@]}"; do
    # Use dpkg -l for installed check; fall back to has_cmd for binaries
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        check_pass "$pkg (installed)"
    elif has_cmd "$pkg"; then
        check_pass "$pkg (on PATH)"
    elif [[ "${INSTALL:-false}" == "true" ]]; then
        # Will be installed below; defer the pass/fail verdict to the outcome.
        MISSING_PKGS+=("$pkg")
    else
        # Check-only / detect mode: the package is installable via apt, so a
        # warn (not a fail) is the honest signal — it flags the phase as
        # needing install (picked up by _detect_phase's warn-delta) without
        # counting toward the exit gate, which must reflect post-install state.
        check_warn "$pkg — not installed (will install)"
        MISSING_PKGS+=("$pkg")
    fi
done

# Install all missing packages in one apt-get call
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Installing: ${MISSING_PKGS[*]}"
        if sudo apt-get update -qq >/dev/null 2>&1 && \
           sudo apt-get install -y "${MISSING_PKGS[@]}" >/dev/null 2>&1; then
            check_pass "System packages installed: ${MISSING_PKGS[*]}"
        else
            check_fail "apt-get install failed for one or more packages"
        fi
    else
        check_warn "Run with --install to install missing packages: ${MISSING_PKGS[*]}"
    fi
fi
