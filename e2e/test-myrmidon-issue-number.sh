#!/usr/bin/env bash
# E2E regression test for issue #187 — Myrmidon must NOT default issue_number to #7.
# Drives resolve_issue_number() in e2e/claude-myrmidon.py via system python3
# (the e2e tree is bash-only; there is no pytest harness — see pixi.toml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/claude-myrmidon.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
fails=0
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; fails=$((fails + 1)); }

# Run resolve_issue_number with a given task_data JSON and ISSUE_NUMBER env.
# Prints the resolved int on success; prints "RAISED" (exit 0) when it raises.
run_resolver() {
  local issue_env="$1" task_json="$2"
  ISSUE_NUMBER="$issue_env" SRC="$SRC" TASK_JSON="$task_json" python3 - <<'PY'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("cm", os.environ["SRC"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
task = json.loads(os.environ["TASK_JSON"])
try:
    print(mod.resolve_issue_number(task))
except ValueError:
    print("RAISED")
PY
}

expect() {  # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}

# Import the module with a given ISSUE_NUMBER env. Prints "IMPORTED" on success,
# "CRASHED" if import raised (issue #325 — malformed ISSUE_NUMBER must not kill
# the worker at module import, before the consumer loop can ack it).
run_import() {
  local issue_env="$1"
  ISSUE_NUMBER="$issue_env" SRC="$SRC" python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("cm", os.environ["SRC"])
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
    print("IMPORTED")
except Exception:
    print("CRASHED")
PY
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Myrmidon issue-number resolver checks (issue #187)  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# 1. message issue_number wins, ignores env
expect "message issue_number used" "187" "$(run_resolver 0 '{"issue_number": 187}')"
# 2. numeric string coerced
expect "numeric string coerced" "42" "$(run_resolver 0 '{"issue_number": "42"}')"
# 3. CORE #187 regression: both absent -> RAISED, never 7
out="$(run_resolver 0 '{}')"
expect "missing both raises (not #7)" "RAISED" "$out"
[ "$out" != "7" ] || fail "resolver returned the forbidden magic number 7"
# 4. env fallback used when message omits it
expect "env ISSUE_NUMBER fallback" "99" "$(run_resolver 99 '{}')"
# 5. invalid/zero/null/non-numeric message values raise
expect "issue_number 0 raises"           "RAISED" "$(run_resolver 0 '{"issue_number": 0}')"
expect "issue_number null raises"        "RAISED" "$(run_resolver 0 '{"issue_number": null}')"
expect "issue_number empty raises"       "RAISED" "$(run_resolver 0 '{"issue_number": ""}')"
expect "issue_number non-numeric raises" "RAISED" "$(run_resolver 0 '{"issue_number": "abc"}')"
expect "issue_number negative raises"    "RAISED" "$(run_resolver 0 '{"issue_number": -3}')"

# 6. CORE #325 regression: malformed ISSUE_NUMBER must not crash module import
expect "import survives ISSUE_NUMBER=foo"  "IMPORTED" "$(run_import foo)"
expect "import survives ISSUE_NUMBER=12.5" "IMPORTED" "$(run_import 12.5)"
expect "import survives ISSUE_NUMBER unset" "IMPORTED" "$(run_import '')"
expect "import survives ISSUE_NUMBER=42"   "IMPORTED" "$(run_import 42)"

# 7. malformed env value surfaces via resolver (acked ValueError), never crashes
expect "non-numeric env raises in resolver" "RAISED" "$(run_resolver foo '{}')"
expect "float-string env raises in resolver" "RAISED" "$(run_resolver 12.5 '{}')"
# message issue_number still wins even when env is garbage
expect "message wins over garbage env" "187" "$(run_resolver foo '{"issue_number": 187}')"

echo ""
if [ "$fails" -eq 0 ]; then
  echo -e "${GREEN}All issue-number resolver checks passed.${NC}"; exit 0
else
  echo -e "${RED}$fails check(s) failed.${NC}"; exit 1
fi
