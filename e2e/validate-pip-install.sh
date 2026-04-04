#!/usr/bin/env bash
# HomericIntelligence Pip Install Validation
# Validates that Python packages can be pip-installed in a clean venv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
VENV_BASE="$(mktemp -d)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; FAILED=1; }
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

FAILED=0

cleanup() {
    rm -rf "$VENV_BASE"
}
trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence Pip Install Validation              ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Package definitions: directory|import_name|cli_entry_points (comma-separated, optional)
PACKAGES=(
    "shared/ProjectHephaestus|hephaestus|hephaestus-changelog,hephaestus-system-info"
    "infrastructure/ProjectHermes|hermes|"
    "provisioning/ProjectTelemachy|telemachy|"
    "research/ProjectScylla|scylla|"
)

for pkg_spec in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg_dir import_name cli_cmds <<< "$pkg_spec"
    pkg_name="$(basename "$pkg_dir")"

    info "Validating $pkg_name"

    pkg_path="$ODYSSEUS_ROOT/$pkg_dir"
    if [ ! -f "$pkg_path/pyproject.toml" ]; then
        echo -e "  ${YELLOW}⊘ SKIP${NC}: $pkg_name (no pyproject.toml)"
        continue
    fi

    venv_dir="$VENV_BASE/$pkg_name"
    python3 -m venv "$venv_dir"
    # shellcheck disable=SC1091
    source "$venv_dir/bin/activate"

    # Install
    if pip install "$pkg_path" --quiet 2>/dev/null; then
        pass "$pkg_name pip install succeeded"
    else
        fail "$pkg_name pip install failed"
        deactivate
        continue
    fi

    # Import check
    if python3 -c "import $import_name" 2>/dev/null; then
        pass "$pkg_name import $import_name succeeded"
    else
        fail "$pkg_name import $import_name failed"
    fi

    # CLI entry point check
    if [ -n "$cli_cmds" ]; then
        IFS=',' read -ra cmds <<< "$cli_cmds"
        for cmd in "${cmds[@]}"; do
            if command -v "$cmd" &>/dev/null; then
                pass "$pkg_name CLI entry point: $cmd"
            else
                fail "$pkg_name CLI entry point missing: $cmd"
            fi
        done
    fi

    deactivate
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}Pip install validation complete — all packages passed.${NC}"
else
    echo -e "${RED}Pip install validation complete — some packages failed.${NC}"
    exit 1
fi
echo ""
