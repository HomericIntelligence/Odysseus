#!/usr/bin/env bash
# Issue #180: the ANTHROPIC_API_KEY *value* must never appear on the container
# command line (visible via `ps auxww` / `/proc/<pid>/cmdline`).
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root
FAIL=0
SECRET="sk-ant-SENTINEL-must-not-leak-180"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# ── Layer 1: built command must not contain the secret VALUE (both workers) ──

# Single worker: env var dropped entirely → neither name nor value present.
ANTHROPIC_API_KEY="$SECRET" python3 - <<'PY' && pass "single: value absent from cmdline" || fail "single: value leaked"
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", "e2e/claude-myrmidon.py")
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
cmd = m._build_container_cmd(["claude-host", "-p", "x"], cwd="/tmp")
joined = " ".join(cmd)
sys.exit(0 if "sk-ant-SENTINEL-must-not-leak-180" not in joined and "ANTHROPIC_API_KEY=" not in joined else 1)
PY

# Multi worker: name-only `-e ANTHROPIC_API_KEY` allowed; the VALUE must be absent
# and there must be NO `ANTHROPIC_API_KEY=` (the with-value leaking form).
ANTHROPIC_API_KEY="$SECRET" python3 - <<'PY' && pass "multi: value absent from cmdline (name-only -e ok)" || fail "multi: value leaked"
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", "e2e/claude-myrmidon-multi.py")
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
bad = False
for scope in ("plan", "review", "test", "implement", "ship"):
    joined = " ".join(m._build_container_cmd_scoped(["claude", "-p", "x"], cwd="/tmp", scope=scope))
    if "sk-ant-SENTINEL-must-not-leak-180" in joined or "ANTHROPIC_API_KEY=" in joined:
        bad = True
sys.exit(1 if bad else 0)
PY

# Multi worker: name-only form must be present (value off cmdline, key still passed).
ANTHROPIC_API_KEY="$SECRET" python3 - <<'PY' && pass "multi: name-only -e ANTHROPIC_API_KEY present" || fail "multi: name-only -e missing"
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", "e2e/claude-myrmidon-multi.py")
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
cmd = m._build_container_cmd_scoped(["claude", "-p", "x"], cwd="/tmp", scope="plan")
# Must find `-e` immediately followed by `ANTHROPIC_API_KEY` (no `=`)
found = False
for i, tok in enumerate(cmd):
    if tok == "-e" and i + 1 < len(cmd) and cmd[i + 1] == "ANTHROPIC_API_KEY":
        found = True
        break
sys.exit(0 if found else 1)
PY

# Single worker: key arg must be absent entirely (not just value hidden).
ANTHROPIC_API_KEY="$SECRET" python3 - <<'PY' && pass "single: ANTHROPIC_API_KEY arg absent entirely" || fail "single: ANTHROPIC_API_KEY arg present"
import importlib.util, sys
s = importlib.util.spec_from_file_location("m", "e2e/claude-myrmidon.py")
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
cmd = m._build_container_cmd(["claude-host", "-p", "x"], cwd="/tmp")
sys.exit(1 if "ANTHROPIC_API_KEY" in " ".join(cmd) else 0)
PY

# ── Layer 2: live container auth smoke check (skips if podman/image absent) ──
IMAGE="${CLAUDE_IMAGE:-achaean-claude:latest}"
if command -v podman >/dev/null 2>&1 && podman image exists "$IMAGE" 2>/dev/null; then
    for W in single multi; do
        OUT=$(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
            python3 e2e/tests/security/_run_one_auth_probe.py "$W" 2>&1) \
            && pass "$W: live container auth OK" \
            || { echo "$OUT" | tail -5; fail "$W: live container auth FAILED"; }
    done
else
    echo "SKIP: podman or image '$IMAGE' unavailable — live auth check skipped (Layer 1 still enforced)"
fi

[ "$FAIL" -eq 0 ] && { echo "ALL CHECKS PASS"; exit 0; } || { echo "CHECKS FAILED"; exit 1; }
