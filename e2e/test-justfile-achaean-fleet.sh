#!/usr/bin/env bash
# E2E test: validate Odysseus fleet-* delegation recipes for AchaeanFleet
# Usage: bash e2e/test-justfile-achaean-fleet.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== AchaeanFleet justfile delegation tests ==="

# ---------------------------------------------------------------------------
# 1. All 6 fleet-* recipes exist in just --summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes exist in 'just --summary' ---"
SUMMARY="$(just --summary)"

for recipe in fleet-build-vessel fleet-build-all fleet-verify fleet-test fleet-push fleet-clean; do
    if echo "$SUMMARY" | tr ' ' '\n' | grep -qx "$recipe"; then
        pass "$recipe found in --summary"
    else
        fail "$recipe NOT found in --summary"
    fi
done

# ---------------------------------------------------------------------------
# 2. All 6 fleet-* recipes appear in just --list
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes appear in 'just --list' ---"
LIST="$(just --list)"

for recipe in fleet-build-vessel fleet-build-all fleet-verify fleet-test fleet-push fleet-clean; do
    if echo "$LIST" | grep -q "$recipe"; then
        pass "$recipe found in --list"
    else
        fail "$recipe NOT found in --list"
    fi
done

# ---------------------------------------------------------------------------
# 3. Delegation paths point to infrastructure/AchaeanFleet
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking delegation paths in justfile ---"

for recipe in fleet-build-vessel fleet-build-all fleet-verify fleet-test fleet-push fleet-clean; do
    # just --show prints the recipe body
    BODY="$(just --show "$recipe" 2>&1)"
    if echo "$BODY" | grep -q "infrastructure/AchaeanFleet"; then
        pass "$recipe delegates to infrastructure/AchaeanFleet"
    else
        fail "$recipe does NOT delegate to infrastructure/AchaeanFleet"
    fi
done

# ---------------------------------------------------------------------------
# 4. Submodule justfile exists and was not modified
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking submodule justfile integrity ---"

SUBMODULE_JUSTFILE="infrastructure/AchaeanFleet/justfile"
if [ -f "$SUBMODULE_JUSTFILE" ]; then
    pass "submodule justfile exists at $SUBMODULE_JUSTFILE"
else
    fail "submodule justfile NOT found at $SUBMODULE_JUSTFILE"
fi

# Check git status for modifications to the submodule justfile
if git diff --quiet -- "$SUBMODULE_JUSTFILE" 2>/dev/null; then
    pass "submodule justfile has no uncommitted modifications"
else
    fail "submodule justfile has uncommitted modifications"
fi

# ---------------------------------------------------------------------------
# 5. fleet-build-vessel accepts a NAME parameter
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking fleet-build-vessel accepts NAME parameter ---"

SHOW_VESSEL="$(just --show fleet-build-vessel 2>&1)"
if echo "$SHOW_VESSEL" | grep -q "NAME"; then
    pass "fleet-build-vessel accepts NAME parameter"
else
    fail "fleet-build-vessel does NOT accept NAME parameter"
fi

# ---------------------------------------------------------------------------
# 6. Submodule justfile has the target recipes we delegate to
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking AchaeanFleet justfile has target recipes ---"

SUBMODULE_SUMMARY="$(cd infrastructure/AchaeanFleet && just --summary 2>&1)"
for target in build-vessel build-all verify test push clean; do
    if echo "$SUBMODULE_SUMMARY" | tr ' ' '\n' | grep -qx "$target"; then
        pass "AchaeanFleet has '$target' recipe"
    else
        fail "AchaeanFleet missing '$target' recipe"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo "All AchaeanFleet delegation tests passed."
exit 0
