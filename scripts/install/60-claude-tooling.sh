#!/usr/bin/env bash
# Phase 60 — Claude Code Tooling
#
# Steps:
#   1. Install Claude Code CLI (via curl installer)
#   2. Merge settings.json: register Hephaestus marketplace + plugin
#   3. Clone or update Mnemosyne agent brain seed
#   4. Install Codex skills from Hephaestus (graceful skip if absent)
#
# Idempotent: each step checks state before acting.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Claude Code Tooling"

# ─── Step 1: Claude Code CLI ─────────────────────────────────────────────────
# Claude Code is developer/interactive tooling: its installer is network-gated
# (fetches from claude.ai) and it is not required for a headless worker to run
# jobs. So a missing/undownloadable CLI is a WARN, not a hard fail — the same
# non-fatal treatment ProjectMnemosyne/Codex already get below, and consistent
# with the network-gated precedent in 40-pixi-envs.sh. This keeps a clean-image
# `--role worker` install at exit 0 when the CLI can't be fetched (#393).
if has_cmd claude; then
    CLAUDE_VER=$(claude --version 2>&1 | head -1)
    check_pass "claude $CLAUDE_VER"
else
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
            check_pass "claude installed"
        else
            check_warn "claude — install failed (network-gated; not required for a headless worker)"
        fi
        # Add ~/.local/bin to PATH idempotently in rc files
        for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$RC" ]] && ! grep -q '\.local/bin' "$RC"; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
                echo -e "    ${BLUE}→${NC} Added ~/.local/bin to PATH in $RC"
            fi
        done
    else
        # Detect / check-only mode: warn (not fail) so this phase is flagged
        # for install without counting toward the exit gate.
        check_warn "claude — not installed (will attempt network install)"
    fi
fi

# ─── Step 2: settings.json merge ─────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"

# Values confirmed from shared/Hephaestus/.claude-plugin/marketplace.json
MARKETPLACE_NAME="Hephaestus"
MARKETPLACE_URL="https://github.com/HomericIntelligence/Hephaestus.git"
PLUGIN_KEY="hephaestus@Hephaestus"

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
        check_pass "settings.json — Hephaestus marketplace and plugin already configured"
    elif [[ "${INSTALL:-false}" == "true" ]]; then
        # Deferred: the merge below is a local, always-succeeds operation and
        # emits its own check_pass. No pre-merge fail — that would linger past
        # the successful merge and trip the exit gate (#393).
        _do_settings_merge=true
    else
        check_warn "settings.json — Hephaestus not registered (will merge)"
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

print("    settings.json updated — Hephaestus registered")
PYEOF
    check_pass "settings.json — Hephaestus marketplace and plugin registered"
fi

# ─── Step 3: Mnemosyne agent brain seed ────────────────────────────────
MNEMOSYNE_DIR="$HOME/.agent-brain/Mnemosyne"
mkdir -p "$HOME/.agent-brain"

if [[ -d "$MNEMOSYNE_DIR/.git" ]]; then
    # Already cloned — try to update
    if git -C "$MNEMOSYNE_DIR" pull --ff-only origin main >/dev/null 2>&1; then
        check_pass "Mnemosyne — up to date"
    else
        check_warn "Mnemosyne pull failed (offline? non-fast-forward?)"
    fi
else
    check_warn "Mnemosyne — not seeded at $MNEMOSYNE_DIR"
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Seeding Mnemosyne..."
        if git clone --depth 1 \
            https://github.com/HomericIntelligence/Mnemosyne \
            "$MNEMOSYNE_DIR" >/dev/null 2>&1; then
            check_pass "Mnemosyne — seeded to $MNEMOSYNE_DIR"
        else
            check_warn "Mnemosyne clone failed (offline? check network)"
        fi
    fi
fi

# ─── Step 4: Codex skills ─────────────────────────────────────────────────────
SKILL_INSTALLER="$ODYSSEUS_ROOT/shared/Hephaestus/skills/.system/skill-installer/scripts/install-skill-from-github.py"

if has_cmd codex; then
    if [[ -f "$SKILL_INSTALLER" ]]; then
        if [[ "${INSTALL:-false}" == "true" ]]; then
            echo -e "    ${BLUE}→${NC} Installing Codex skills from Hephaestus..."
            if python3 "$SKILL_INSTALLER" \
                --repo HomericIntelligence/Hephaestus \
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
        check_warn "Codex: skill-installer not present in Hephaestus (skipped)"
    fi
else
    check_warn "Codex: binary not found on PATH (skipped)"
fi
