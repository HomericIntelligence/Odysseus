#!/usr/bin/env bash
# Phase 60 — Claude Code Tooling
#
# Steps:
#   1. Install Claude Code CLI (via curl installer)
#   2. Merge settings.json: register ProjectHephaestus marketplace + plugin
#   3. Clone or update ProjectMnemosyne agent brain seed
#   4. Install Codex skills from ProjectHephaestus (graceful skip if absent)
#
# Idempotent: each step checks state before acting.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Claude Code Tooling"

# ─── Step 1: Claude Code CLI ─────────────────────────────────────────────────
if has_cmd claude; then
    CLAUDE_VER=$(claude --version 2>&1 | head -1)
    check_pass "claude $CLAUDE_VER"
else
    check_fail "claude — NOT FOUND"
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
            check_pass "claude installed"
        else
            check_fail "claude — install failed (see https://claude.ai/code)"
        fi
        # Add ~/.local/bin to PATH idempotently in rc files
        for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$RC" ]] && ! grep -q '\.local/bin' "$RC"; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
                echo -e "    ${BLUE}→${NC} Added ~/.local/bin to PATH in $RC"
            fi
        done
    fi
fi

# ─── Step 2: settings.json merge ─────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

# Values confirmed from shared/ProjectHephaestus/.claude-plugin/marketplace.json
MARKETPLACE_NAME="ProjectHephaestus"
MARKETPLACE_URL="https://github.com/HomericIntelligence/ProjectHephaestus.git"
PLUGIN_KEY="hephaestus@ProjectHephaestus"

if [[ -f "$SETTINGS" ]]; then
    # Check if already configured
    if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    s = json.load(f)
marketplaces = s.get('extraKnownMarketplaces', {})
plugins = s.get('enabledPlugins', {})
ok = ('$MARKETPLACE_NAME' in marketplaces and '$PLUGIN_KEY' in plugins)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
        check_pass "settings.json — ProjectHephaestus marketplace and plugin already configured"
    else
        check_fail "settings.json — ProjectHephaestus not registered"
        if [[ "${INSTALL:-false}" == "true" ]]; then
            _do_settings_merge=true
        fi
    fi
else
    check_warn "settings.json — not found (will create)"
    [[ "${INSTALL:-false}" == "true" ]] && _do_settings_merge=true
fi

if [[ "${_do_settings_merge:-false}" == "true" ]]; then
    python3 - <<PYEOF
import json, os, shutil, time

settings_path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(settings_path):
    shutil.copy(settings_path, settings_path + ".bak." + str(int(time.time())))
    with open(settings_path) as f:
        s = json.load(f)
else:
    s = {}

s.setdefault("extraKnownMarketplaces", {})["$MARKETPLACE_NAME"] = {
    "source": {"source": "git", "url": "$MARKETPLACE_URL"}
}
s.setdefault("enabledPlugins", {})["$PLUGIN_KEY"] = True

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)

print("    settings.json updated — ProjectHephaestus registered")
PYEOF
    check_pass "settings.json — ProjectHephaestus marketplace and plugin registered"
fi

# ─── Step 3: ProjectMnemosyne agent brain seed ────────────────────────────────
MNEMOSYNE_DIR="$HOME/.agent-brain/ProjectMnemosyne"
mkdir -p "$HOME/.agent-brain"

if [[ -d "$MNEMOSYNE_DIR/.git" ]]; then
    # Already cloned — try to update
    if git -C "$MNEMOSYNE_DIR" pull --ff-only origin main >/dev/null 2>&1; then
        check_pass "ProjectMnemosyne — up to date"
    else
        check_warn "ProjectMnemosyne pull failed (offline? non-fast-forward?)"
    fi
else
    check_warn "ProjectMnemosyne — not seeded at $MNEMOSYNE_DIR"
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Seeding ProjectMnemosyne..."
        if git clone --depth 1 \
            https://github.com/HomericIntelligence/ProjectMnemosyne \
            "$MNEMOSYNE_DIR" >/dev/null 2>&1; then
            check_pass "ProjectMnemosyne — seeded to $MNEMOSYNE_DIR"
        else
            check_warn "ProjectMnemosyne clone failed (offline? check network)"
        fi
    fi
fi

# ─── Step 4: Codex skills ─────────────────────────────────────────────────────
SKILL_INSTALLER="$ODYSSEUS_ROOT/shared/ProjectHephaestus/skills/.system/skill-installer/scripts/install-skill-from-github.py"

if has_cmd codex; then
    if [[ -f "$SKILL_INSTALLER" ]]; then
        if [[ "${INSTALL:-false}" == "true" ]]; then
            echo -e "    ${BLUE}→${NC} Installing Codex skills from ProjectHephaestus..."
            if python3 "$SKILL_INSTALLER" \
                --repo HomericIntelligence/ProjectHephaestus \
                --path skills/repo-analyze skills/repo-analyze-quick skills/repo-analyze-strict \
                       skills/advise skills/learn \
                --dest "$HOME/.codex/skills" 2>&1; then
                check_pass "Codex skills installed"
            else
                check_warn "Codex skills — installer encountered errors (non-fatal)"
            fi
        else
            if [[ -d "$HOME/.codex/skills" ]]; then
                check_pass "Codex skills directory present"
            else
                check_warn "Codex skills not installed (run with --install)"
            fi
        fi
    else
        check_warn "Codex: skill-installer not present in ProjectHephaestus (skipped)"
    fi
else
    check_warn "Codex: binary not found on PATH (skipped)"
fi
