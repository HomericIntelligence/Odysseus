#!/usr/bin/env bash
set -euo pipefail

# Test script: CI workflow harden job (issue #22 / PR #144)
# Verifies that .github/workflows/ci.yml contains a proper harden job
# with all required steps and correct dependencies.

CI_FILE=".github/workflows/ci.yml"
PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

check_grep() {
    local desc="$1"; local pattern="$2"
    if grep -qE "$pattern" "$CI_FILE" 2>/dev/null; then pass "$desc"; else fail "$desc"; fi
}

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 1: File existence ==="
# ═══════════════════════════════════════════════════════════════════

if [ ! -f "$CI_FILE" ]; then
    fail "CI workflow file exists at $CI_FILE"
    echo "FATAL: CI file not found. Cannot continue."
    echo "Result: 0 passed, 1 failed"
    exit 1
fi
pass "CI workflow file exists at $CI_FILE"

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 2: validate job preserved ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "validate job is present" '^  validate:'
check_grep "validate job lints YAML configs" 'yamllint'
check_grep "validate job uses ubuntu-latest" 'ubuntu-latest'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 3: harden job present ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "harden job is present" '^  harden:'
check_grep "harden job runs on ubuntu-latest" 'ubuntu-latest'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 4: harden job depends on validate ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "needs: [validate] present" 'needs:.*\[validate\]'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 5: markdownlint step ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "markdownlint-cli is installed" 'markdownlint-cli'
check_grep "markdownlint runs on docs/architecture.md" 'markdownlint.*docs/architecture\.md'
check_grep "markdownlint runs on docs/adr/" 'markdownlint.*docs/adr'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 6: pixi manifest validation step ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "pixi info validates manifest" 'pixi info.*pixi\.toml'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 7: justfile validation step ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "just --summary validates justfile" 'just.*--summary'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 8: symlink integrity audit step ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "symlink audit uses find -type l" 'find.*-type l'
check_grep "symlink audit checks for broken links" 'BROKEN|! -e'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 9: conditional verify_claude_read_permissions step ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "verify_claude_read_permissions.py referenced" 'verify_claude_read_permissions\.py'
check_grep "step is conditional (skips if absent)" 'if \[ -f.*verify_claude_read_permissions'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 10: job ordering ==="
# ═══════════════════════════════════════════════════════════════════

VALIDATE_LINE=$(grep -n '^  validate:' "$CI_FILE" | head -1 | cut -d: -f1)
HARDEN_LINE=$(grep -n '^  harden:' "$CI_FILE" | head -1 | cut -d: -f1)

if [ -n "$VALIDATE_LINE" ] && [ -n "$HARDEN_LINE" ] && [ "$VALIDATE_LINE" -lt "$HARDEN_LINE" ]; then
    pass "validate job defined before harden job"
else
    fail "validate job defined before harden job"
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Result: $PASS_COUNT passed, $FAIL_COUNT failed (out of $TOTAL checks)"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
else
    echo "ALL CHECKS PASSED"
    exit 0
fi
