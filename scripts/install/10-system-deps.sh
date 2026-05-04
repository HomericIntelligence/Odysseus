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

# Collect missing packages
MISSING_PKGS=()
for pkg in "${APT_PKGS[@]}"; do
    # Use dpkg -l for installed check; fall back to has_cmd for binaries
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        check_pass "$pkg (installed)"
    elif has_cmd "$pkg"; then
        check_pass "$pkg (on PATH)"
    else
        check_fail "$pkg — NOT FOUND"
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
