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

# Values confirmed from shared/Hephaestus/.claude-plugin/marketplace.json
MARKETPLACE_NAME="Hephaestus"
MARKETPLACE_URL="https://github.com/HomericIntelligence/Hephaestus.git"
PLUGIN_KEY="hephaestus@Hephaestus"
# Per ADR-016, also register the Athena marketplace + plugin (the agentic-plugins
# half of the Hephaestus -> Hephaestus + Athena split). Athena hosts Claude Code
# marketplace plugins; skills code that needs the `hephaestus` orchestrator library
# continues to `pip install hephaestus[automation]` from the Hephaestus repo.
ATHENA_MARKETPLACE_NAME="Athena"
ATHENA_MARKETPLACE_URL="https://github.com/HomericIntelligence/Athena.git"
ATHENA_PLUGIN_KEY="athena@Athena"

if [[ -f "$SETTINGS" ]]; then
    # Check if BOTH Hephaestus and Athena are configured (ADR-016 split carve-out).
    # Presence of the marketplace key is NOT sufficient: a user with the PRE-rename
    # `Hephaestus` -> `ProjectHephaestus.git` URL would otherwise be reported
    # as correctly configured, then 404 silently at marketplace load. Require the
    # URL to actually match the canonical value.
    if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    s = json.load(f)
mp = s.get('extraKnownMarketplaces', {})
pl = s.get('enabledPlugins', {})
h = mp.get('$MARKETPLACE_NAME', {})
a = mp.get('$ATHENA_MARKETPLACE_NAME', {})
h_ok = isinstance(h, dict) and isinstance(h.get('source'), dict) and h['source'].get('url') == '$MARKETPLACE_URL'
a_ok = isinstance(a, dict) and isinstance(a.get('source'), dict) and a['source'].get('url') == '$ATHENA_MARKETPLACE_URL'
ok = (h_ok and '$PLUGIN_KEY' in pl and a_ok and '$ATHENA_PLUGIN_KEY' in pl)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
        check_pass "settings.json — Hephaestus + Athena marketplaces and plugins already configured (URLs match)"
    else
        check_fail "settings.json — Hephaestus and/or Athena not registered (or stale URL)"
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

mp = s.setdefault("extraKnownMarketplaces", {})
plugins = s.setdefault("enabledPlugins", {})

# Register Hephaestus marketplace + plugin (the library half of ADR-016).
# Idempotent AND URL-aware: a plain setdefault would silently preserve a
# stale `Hephaestus` URL (e.g. the dead pre-rename `ProjectHephaestus.git`
# reference) and the marketplace load would 404. Overwrite only when the
# existing URL does not match the canonical one.
existing_h = mp.get("$MARKETPLACE_NAME")
h_url_match = (
    isinstance(existing_h, dict)
    and isinstance(existing_h.get("source"), dict)
    and existing_h["source"].get("url") == "$MARKETPLACE_URL"
)
if not h_url_match:
    mp["$MARKETPLACE_NAME"] = {"source": {"source": "git", "url": "$MARKETPLACE_URL"}}

# Same URL-aware overwrite for the Athena marketplace + plugin key.
existing_a = mp.get("$ATHENA_MARKETPLACE_NAME")
a_url_match = (
    isinstance(existing_a, dict)
    and isinstance(existing_a.get("source"), dict)
    and existing_a["source"].get("url") == "$ATHENA_MARKETPLACE_URL"
)
if not a_url_match:
    mp["$ATHENA_MARKETPLACE_NAME"] = {"source": {"source": "git", "url": "$ATHENA_MARKETPLACE_URL"}}

# Plugin keys: enable unconditionally. The install script's job is to put the
# dev environment into a KNOWN-GOOD state; if a user previously disabled a
# plugin, the install script re-enables it. For a syncing/share tool we would
# use `setdefault` instead, but this is an installer.
plugins["$PLUGIN_KEY"] = True
plugins["$ATHENA_PLUGIN_KEY"] = True

# Migration cleanup: drop any PRE-RENAME plugin keys if a user is upgrading
# from a pre-ADR-016 install. The marketplace name changed from
# `ProjectHephaestus` -> `Hephaestus`, so the old `hephaestus@ProjectHephaestus`
# is dead; leaving it in `enabledPlugins` causes a noise-level 404 / EACCES on
# every plugin enumeration. Extend the tuple if pre-ADR-016 cruft surfaces
# again (e.g., from the pre-ADR-006 ai-maestro era).
LEGACY_PLUGIN_KEYS = (
    "hephaestus@ProjectHephaestus",
)
purged_legacy = 0
for legacy_key in LEGACY_PLUGIN_KEYS:
    if plugins.pop(legacy_key, None) is not None:
        purged_legacy += 1

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)

# Per-action message: includes the legacy-purge count when applicable. This is
# the AUTHORITATIVE user-visible result for this step; the bash `check_pass`
# below just confirms success without trying to inspect Python locals (which
# would not propagate across the heredoc boundary).
if purged_legacy:
    print(f"    settings.json updated — Hephaestus + Athena marketplaces and plugins reconciled ({purged_legacy} legacy plugin key(s) purged)")
else:
    print("    settings.json updated — Hephaestus + Athena marketplaces and plugins reconciled")
PYEOF
    # Confirm success. Do NOT try to branch on Python locals here — they do
    # not propagate across the heredoc boundary (a real bug that would trip
    # `set -u` nounset + `[ "" -gt 0 ]` integer-expression errors). Python's
    # print above already carries the per-action detail, including the
    # legacy-purge count when applicable.
    check_pass "settings.json — Hephaestus + Athena marketplaces and plugins reconciled"
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
