#!/usr/bin/env bash
# E2E test: validate Odysseus hephaestus-* delegation recipes for ProjectHephaestus
# Usage: bash e2e/test-justfile-hephaestus.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== ProjectHephaestus justfile delegation tests ==="

# ---------------------------------------------------------------------------
# 1. All 6 hephaestus-* recipes exist in just --summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes exist in 'just --summary' ---"
SUMMARY="$(just --summary)"

for recipe in hephaestus-test hephaestus-lint hephaestus-format hephaestus-typecheck hephaestus-check hephaestus-audit; do
    if echo "$SUMMARY" | tr ' ' '\n' | grep -qx "$recipe"; then
        pass "$recipe found in --summary"
    else
        fail "$recipe NOT found in --summary"
    fi
done

# ---------------------------------------------------------------------------
# 2. All 6 hephaestus-* recipes appear in just --list
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes appear in 'just --list' ---"
LIST="$(just --list)"

for recipe in hephaestus-test hephaestus-lint hephaestus-format hephaestus-typecheck hephaestus-check hephaestus-audit; do
    if echo "$LIST" | grep -q "$recipe"; then
        pass "$recipe found in --list"
    else
        fail "$recipe NOT found in --list"
    fi
done

# ---------------------------------------------------------------------------
# 3. Delegation paths point to shared/ProjectHephaestus
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking delegation paths in justfile ---"

for recipe in hephaestus-test hephaestus-lint hephaestus-format hephaestus-typecheck hephaestus-check hephaestus-audit; do
    BODY="$(just --show "$recipe" 2>&1)"
    if echo "$BODY" | grep -q "shared/ProjectHephaestus"; then
        pass "$recipe delegates to shared/ProjectHephaestus"
    else
        fail "$recipe does NOT delegate to shared/ProjectHephaestus"
    fi
done

# ---------------------------------------------------------------------------
# 4. Submodule justfile exists and was not modified
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking submodule justfile integrity ---"

SUBMODULE_JUSTFILE="shared/ProjectHephaestus/justfile"
if [ -f "$SUBMODULE_JUSTFILE" ]; then
    pass "submodule justfile exists at $SUBMODULE_JUSTFILE"
else
    fail "submodule justfile NOT found at $SUBMODULE_JUSTFILE"
fi

if git diff --quiet -- "$SUBMODULE_JUSTFILE" 2>/dev/null; then
    pass "submodule justfile has no uncommitted modifications"
else
    fail "submodule justfile has uncommitted modifications"
fi

# ---------------------------------------------------------------------------
# 5. Submodule justfile has the target recipes we delegate to
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking ProjectHephaestus justfile has target recipes ---"

SUBMODULE_SUMMARY="$(cd shared/ProjectHephaestus && just --summary 2>&1)"
for target in test lint format typecheck check audit; do
    if echo "$SUBMODULE_SUMMARY" | tr ' ' '\n' | grep -qx "$target"; then
        pass "ProjectHephaestus has '$target' recipe"
    else
        fail "ProjectHephaestus missing '$target' recipe"
    fi
done

# ---------------------------------------------------------------------------
# 6. Section header exists in Odysseus justfile
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking section header ---"

if grep -q "Shared Utilities (ProjectHephaestus)" justfile; then
    pass "Shared Utilities (ProjectHephaestus) section header exists"
else
    fail "Shared Utilities (ProjectHephaestus) section header missing"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo "All ProjectHephaestus delegation tests passed."
exit 0
