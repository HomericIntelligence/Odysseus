#!/usr/bin/env bash
# Phase 60 — Claude Code Tooling
#
# Steps:
#   1. Install Claude Code CLI (via curl installer)
<<<<<<< HEAD
#   2. Merge settings.json: register Athena marketplace + plugin (Hephaestus removed per user directive)
=======
#   2. Merge settings.json: register Hephaestus marketplace + plugin
>>>>>>> origin/chore/split-hephaestus-athena
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

<<<<<<< HEAD
# The Athena marketplace + plugin is the sole Claude Code surface registered
# by this install script. The Hephaestus marketplace registration that this
# script previously wrote has been removed per the user's directive; the
# `hephaestus` orchestrator library remains installable directly from the
# Hephaestus repo (pip install hephaestus[automation]) without any Claude
# Code marketplace registration required.
# URL matches .gitmodules [submodule "agentic/Athena"].
ATHENA_MARKETPLACE_NAME="Athena"
ATHENA_MARKETPLACE_URL="https://github.com/HomericIntelligence/Athena.git"
ATHENA_PLUGIN_KEY="athena@Athena"

# Plugin keys from PRE-ADR-016 installs (dead marketplace names), the
# non-canonical `hephaestus@Athena` mapping (Claude Code auto-resolved
# `hephaestus` to the Athena marketplace at some point), and the canonical
# `hephaestus@Hephaestus` key that this install script used to register but
# no longer does (per the user's directive). All three are now cleaned
# on --install — leaving any of them in enabledPlugins causes noise-level
# 404s on every plugin enumeration. Space-separated so it can be .split()
# into a Python tuple. Single source of truth — both the precondition
# diagnostic AND the merge purge derive from this; add new legacy keys
# here only.
LEGACY_PLUGIN_KEYS_CSV="hephaestus@ProjectHephaestus hephaestus@Hephaestus hephaestus@Athena"
=======
# Values confirmed from shared/Hephaestus/.claude-plugin/marketplace.json
MARKETPLACE_NAME="Hephaestus"
MARKETPLACE_URL="https://github.com/HomericIntelligence/Hephaestus.git"
PLUGIN_KEY="hephaestus@Hephaestus"
>>>>>>> origin/chore/split-hephaestus-athena

if [[ -f "$SETTINGS" ]]; then
    # Per-item diagnostic (Athena marketplace + plugin conformance). Python's
    # stdout is captured into DIAGNOSTICS via command substitution. Safe
    # because the data flows through the COMMAND (stdout -> bash variable via
    # $()), not through Python-to-bash variable scope (which doesn't work;
    # see bug note in the merge block below). Detects canonical-marketplace
    # presence, missing plugin keys, and any non-canonical legacy plugin
    # keys. URL comparison tolerates trailing-slash and with/without-.git
    # variants.
    if DIAGNOSTICS=$(python3 2>/dev/null <<PYEOF
import json, sys
with open("$SETTINGS") as f:
    s = json.load(f)
<<<<<<< HEAD
mp = s.get("extraKnownMarketplaces", {})
pl = s.get("enabledPlugins", {})

def get_url(name):
    e = mp.get(name)
    if not isinstance(e, dict):
        return ""
    src = e.get("source")
    if not isinstance(src, dict):
        return ""
    return src.get("url") or ""

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

a_ok = norm(get_url("$ATHENA_MARKETPLACE_NAME")) == norm("$ATHENA_MARKETPLACE_URL")
p_a = pl.get("$ATHENA_PLUGIN_KEY") is True
legacy = [k for k in "$LEGACY_PLUGIN_KEYS_CSV".split() if k in pl]

if a_ok and p_a and not legacy:
    sys.exit(0)

def fmt_marketplace(name, ok, actual):
    if ok:
        return "marketplace " + name + ": present"
    return "marketplace " + name + ": missing or wrong URL (found: " + (actual or "not configured") + ")"

out = []
out.append(fmt_marketplace("$ATHENA_MARKETPLACE_NAME", a_ok, get_url("$ATHENA_MARKETPLACE_NAME")))
out.append("plugin $ATHENA_PLUGIN_KEY: " + ("enabled" if p_a else "missing or disabled"))
if legacy:
    out.append("non-canonical plugin keys present (will be cleaned on --install): " + ", ".join(legacy))
print("\n".join(out))
sys.exit(1)
PYEOF
); then
        check_pass "settings.json — Athena marketplace and plugin configured"
    else
        check_fail "settings.json — Athena marketplace+plugin gap detected:
$DIAGNOSTICS
tip: re-run with --install to apply the canonical fix; or manually edit ~/.claude/settings.json"
        [[ "${INSTALL:-false}" == "true" ]] && _do_settings_merge=true
=======
marketplaces = s.get('extraKnownMarketplaces', {})
plugins = s.get('enabledPlugins', {})
ok = ('$MARKETPLACE_NAME' in marketplaces and '$PLUGIN_KEY' in plugins)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
        check_pass "settings.json — Hephaestus marketplace and plugin already configured"
    else
        check_fail "settings.json — Hephaestus not registered"
        if [[ "${INSTALL:-false}" == "true" ]]; then
            _do_settings_merge=true
        fi
>>>>>>> origin/chore/split-hephaestus-athena
    fi
else
    check_warn "settings.json — not found (will create)"
    [[ "${INSTALL:-false}" == "true" ]] && _do_settings_merge=true
fi

if [[ "${_do_settings_merge:-false}" == "true" ]]; then
    python3 - <<PYEOF
import json, os, shutil, time

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

settings_path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(settings_path):
    shutil.copy(settings_path, settings_path + ".bak." + str(int(time.time())))
    with open(settings_path) as f:
        s = json.load(f)
else:
    s = {}

mp = s.setdefault("extraKnownMarketplaces", {})
plugins = s.setdefault("enabledPlugins", {})

# Register the Athena marketplace + plugin (URL-aware idempotency: a plain
# setdefault would silently preserve a stale URL on disk; we only overwrite
# when the existing URL does not match the canonical one).
existing_a = mp.get("$ATHENA_MARKETPLACE_NAME")
a_url_match = (
    isinstance(existing_a, dict)
    and isinstance(existing_a.get("source"), dict)
    and norm(existing_a["source"].get("url")) == norm("$ATHENA_MARKETPLACE_URL")
)
if not a_url_match:
    mp["$ATHENA_MARKETPLACE_NAME"] = {"source": {"source": "git", "url": "$ATHENA_MARKETPLACE_URL"}}

# Plugin keys: enable unconditionally. The install script's job is to put the
# dev environment into a KNOWN-GOOD state; if a user previously disabled a
# plugin, the install script re-enables it. For a syncing/share tool we would
# use 'setdefault' instead, but this is an installer.
plugins["$ATHENA_PLUGIN_KEY"] = True

# Migration cleanup: drop any LEGACY plugin keys (pre-rename
# 'ProjectHephaestus'; the canonical 'hephaestus@Hephaestus' which this
# install script no longer registers per the user's athena-only directive;
# and the non-canonical 'hephaestus@Athena' mapping Claude Code auto-resolved
# at some point, where the marketplace name is incorrectly 'Athena' instead
# of 'Hephaestus'). Leaving any of them in 'enabledPlugins' causes noise-level
# 404s on every plugin enumeration. Source of truth is $LEGACY_PLUGIN_KEYS_CSV
# at the top of this step — extend it (not this tuple) if more cruft surfaces.
LEGACY_PLUGIN_KEYS = "$LEGACY_PLUGIN_KEYS_CSV".split()
purged_legacy = 0
for legacy_key in LEGACY_PLUGIN_KEYS:
    if plugins.pop(legacy_key, None) is not None:
        purged_legacy += 1

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)

<<<<<<< HEAD
# Per-action message: includes the legacy-purge count when applicable. This is
# the AUTHORITATIVE user-visible result for this step; the bash 'check_pass'
# below just confirms success without trying to inspect Python locals (which
# would not propagate across the heredoc boundary).
if purged_legacy:
    print(f"    settings.json updated — Athena marketplace and plugin reconciled ({purged_legacy} legacy plugin key(s) purged)")
else:
    print("    settings.json updated — Athena marketplace and plugin reconciled")
PYEOF
    # Confirm success. Do NOT try to branch on Python locals here — they do
    # not propagate across the heredoc boundary (a real bug that would trip
    # `set -u` nounset + `[ "" -gt 0 ]` integer-expression errors). Python's
    # print above already carries the per-action detail, including the
    # legacy-purge count when applicable.
    check_pass "settings.json — Athena marketplace and plugin reconciled"
=======
print("    settings.json updated — Hephaestus registered")
PYEOF
    check_pass "settings.json — Hephaestus marketplace and plugin registered"
>>>>>>> origin/chore/split-hephaestus-athena
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
