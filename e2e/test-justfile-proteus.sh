#!/usr/bin/env bash
# E2E test: validate Odysseus proteus-* delegation recipes for ProjectProteus
# Usage: bash e2e/test-justfile-proteus.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== ProjectProteus justfile delegation tests ==="

# ---------------------------------------------------------------------------
# 1. All 5 proteus-* recipes exist in just --summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes exist in 'just --summary' ---"
SUMMARY="$(just --summary)"

for recipe in proteus-pipeline proteus-build proteus-validate proteus-dispatch proteus-lint; do
    if echo "$SUMMARY" | tr ' ' '\n' | grep -qx "$recipe"; then
        pass "$recipe found in --summary"
    else
        fail "$recipe NOT found in --summary"
    fi
done

# ---------------------------------------------------------------------------
# 2. All 5 proteus-* recipes appear in just --list
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipes appear in 'just --list' ---"
LIST="$(just --list)"

for recipe in proteus-pipeline proteus-build proteus-validate proteus-dispatch proteus-lint; do
    if echo "$LIST" | grep -q "$recipe"; then
        pass "$recipe found in --list"
    else
        fail "$recipe NOT found in --list"
    fi
done

# ---------------------------------------------------------------------------
# 3. Recipe descriptions are present in just --list
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking recipe descriptions ---"

if echo "$LIST" | grep "proteus-pipeline" | grep -qi "pipeline"; then
    pass "proteus-pipeline has description"
else
    fail "proteus-pipeline missing description"
fi

if echo "$LIST" | grep "proteus-validate" | grep -qi "validate"; then
    pass "proteus-validate has description"
else
    fail "proteus-validate missing description"
fi

# ---------------------------------------------------------------------------
# 4. Delegation paths point to ci-cd/ProjectProteus
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking delegation paths in justfile ---"

for recipe in proteus-pipeline proteus-build proteus-validate proteus-dispatch proteus-lint; do
    BODY="$(just --show "$recipe" 2>&1)"
    if echo "$BODY" | grep -q "ci-cd/ProjectProteus"; then
        pass "$recipe delegates to ci-cd/ProjectProteus"
    else
        fail "$recipe does NOT delegate to ci-cd/ProjectProteus"
    fi
done

# ---------------------------------------------------------------------------
# 5. Parameterized recipes accept the correct parameter
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking parameterized recipes ---"

SHOW_PIPELINE="$(just --show proteus-pipeline 2>&1)"
if echo "$SHOW_PIPELINE" | grep -q "NAME"; then
    pass "proteus-pipeline accepts NAME parameter"
else
    fail "proteus-pipeline does NOT accept NAME parameter"
fi

if echo "$SHOW_PIPELINE" | grep -q "just pipeline"; then
    pass "proteus-pipeline delegates to 'just pipeline'"
else
    fail "proteus-pipeline does NOT delegate to 'just pipeline'"
fi

SHOW_BUILD="$(just --show proteus-build 2>&1)"
if echo "$SHOW_BUILD" | grep -q "NAME"; then
    pass "proteus-build accepts NAME parameter"
else
    fail "proteus-build does NOT accept NAME parameter"
fi

# ---------------------------------------------------------------------------
# 6. proteus-dispatch delegates to dispatch-apply with HOST parameter
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking proteus-dispatch delegation ---"

SHOW_DISPATCH="$(just --show proteus-dispatch 2>&1)"
if echo "$SHOW_DISPATCH" | grep -q "HOST"; then
    pass "proteus-dispatch accepts HOST parameter"
else
    fail "proteus-dispatch does NOT accept HOST parameter"
fi

if echo "$SHOW_DISPATCH" | grep -q "dispatch-apply"; then
    pass "proteus-dispatch delegates to 'just dispatch-apply'"
else
    fail "proteus-dispatch does NOT delegate to 'just dispatch-apply'"
fi

# ---------------------------------------------------------------------------
# 7. Submodule justfile exists and was not modified
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking submodule justfile integrity ---"

SUBMODULE_JUSTFILE="ci-cd/ProjectProteus/justfile"
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
# 8. Submodule justfile has the target recipes we delegate to
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking ProjectProteus justfile has target recipes ---"

SUBMODULE_SUMMARY="$(cd ci-cd/ProjectProteus && just --summary 2>&1)"
for target in pipeline build validate dispatch-apply lint; do
    if echo "$SUBMODULE_SUMMARY" | tr ' ' '\n' | grep -qx "$target"; then
        pass "ProjectProteus has '$target' recipe"
    else
        fail "ProjectProteus missing '$target' recipe"
    fi
done

# ---------------------------------------------------------------------------
# 9. Section header exists in Odysseus justfile
# ---------------------------------------------------------------------------
echo ""
echo "--- Checking section header ---"

if grep -q "CI/CD.*ProjectProteus" justfile; then
    pass "CI/CD (ProjectProteus) section header exists"
else
    fail "CI/CD (ProjectProteus) section header missing"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo "All ProjectProteus delegation tests passed."
exit 0
