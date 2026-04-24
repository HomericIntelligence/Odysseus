#!/usr/bin/env bash
# e2e/test-build-idempotent.sh
# Regression test: run 'just build' twice, assert all four C++ artifact dirs survive.
#
# Usage: bash e2e/test-build-idempotent.sh
# Exit 0 = PASS, exit 1 = FAIL
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../" && pwd)"
BUILD_ROOT="${REPO_ROOT}/build"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local path="$2"
    if [[ -f "$path" ]]; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc — missing: $path"
        FAIL=$((FAIL + 1))
    fi
}

cd "$REPO_ROOT"

echo "=== Step 1: clean slate ==="
rm -rf "$BUILD_ROOT"

echo "=== Step 2: first build ==="
pixi run just build

echo "=== Step 3: assert artifacts after first build ==="
check "Agamemnon CMakeCache (run 1)"  "${BUILD_ROOT}/ProjectAgamemnon/CMakeCache.txt"
check "Nestor CMakeCache (run 1)"     "${BUILD_ROOT}/ProjectNestor/CMakeCache.txt"
check "Charybdis CMakeCache (run 1)"  "${BUILD_ROOT}/ProjectCharybdis/CMakeCache.txt"
check "Keystone CMakeCache (run 1)"   "${BUILD_ROOT}/ProjectKeystone/CMakeCache.txt"

echo "=== Step 4: second build (idempotency check) ==="
pixi run just build

echo "=== Step 5: assert artifacts survive second build ==="
check "Agamemnon CMakeCache (run 2)"  "${BUILD_ROOT}/ProjectAgamemnon/CMakeCache.txt"
check "Nestor CMakeCache (run 2)"     "${BUILD_ROOT}/ProjectNestor/CMakeCache.txt"
check "Charybdis CMakeCache (run 2)"  "${BUILD_ROOT}/ProjectCharybdis/CMakeCache.txt"
check "Keystone CMakeCache (run 2)"   "${BUILD_ROOT}/ProjectKeystone/CMakeCache.txt"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
