#!/usr/bin/env bash
# Structural checks for the repository-owned agent entry points.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }

expected=$(mktemp "${TMPDIR:-/tmp}/odysseus-claude-pointer.XXXXXX")
trap 'rm -f "$expected"' EXIT
printf '%s\n' \
    '# Claude Code guidance' \
    '' \
    'Follow [`AGENTS.md`](AGENTS.md). It is the sole authoritative agent contract for this repository.' \
    > "$expected"

if [ -f "$ROOT/CLAUDE.md" ] && [ ! -L "$ROOT/CLAUDE.md" ] \
   && cmp -s "$expected" "$ROOT/CLAUDE.md"; then
    pass "CLAUDE.md is the exact compatibility pointer"
else
    fail "CLAUDE.md must be the exact direct-file compatibility pointer"
fi

if [ -s "$ROOT/AGENTS.md" ] && [ ! -L "$ROOT/AGENTS.md" ]; then
    pass "AGENTS.md is a non-empty repository-owned contract"
else
    fail "AGENTS.md must be a non-empty direct regular file"
fi

if python3 - "$ROOT/.claude/settings.json" <<'PY'
import json
import os
import stat
import sys

path = sys.argv[1]
mode = os.lstat(path).st_mode
if not stat.S_ISREG(mode):
    raise SystemExit("settings path is not a direct regular file")
with open(path, encoding="utf-8") as stream:
    settings = json.load(stream)

if settings.get("enabledPlugins", {}).get("athena@Athena") is not True:
    raise SystemExit("athena@Athena is not enabled")
source = settings.get("extraKnownMarketplaces", {}).get("Athena", {}).get("source")
if source != {
    "source": "git",
    "url": "https://github.com/HomericIntelligence/Athena.git",
}:
    raise SystemExit("Athena marketplace source is not canonical")
if any("hephaestus" in key.lower() for key in settings.get("enabledPlugins", {})):
    raise SystemExit("duplicate Hephaestus plugin exposure remains")
PY
then
    pass "Claude settings expose the canonical Athena plugin identity"
else
    fail "Claude settings do not expose the canonical Athena plugin identity"
fi

if [ ! -e "$ROOT/agents/openai.yaml" ] && [ ! -L "$ROOT/agents/openai.yaml" ]; then
    pass "no provider-specific agents/openai.yaml surface exists"
else
    fail "agents/openai.yaml is outside the provider-neutral contract"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
