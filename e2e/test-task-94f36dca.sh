```bash
#!/usr/bin/env bash

set -euo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" = "pass" ]; then
    echo "PASS: $desc"
    ((PASS++)) || true
  else
    echo "FAIL: $desc"
    ((FAIL++)) || true
  fi
}

CI_FILE=".github/workflows/ci.yml"

# AC1: harden job exists and needs validate
if [ -f "$CI_FILE" ]; then
  if grep -q "harden:" "$CI_FILE" && grep -A5 "harden:" "$CI_FILE" | grep -q "needs:.*validate\|needs:.*\[validate\]"; then
    check "AC1: ci.yml has a 'harden' job with needs: [validate]" "pass"
  else
    check "AC1: ci.yml has a 'harden' job with needs: [validate]" "fail"
  fi
else
  check "AC1: ci.yml exists" "fail"
fi

# AC2: markdownlint step present
if [ -f "$CI_FILE" ] && grep -q "markdownlint" "$CI_FILE"; then
  if grep -q "docs/architecture.md" "$CI_FILE" && grep -q "docs/adr" "$CI_FILE"; then
    check "AC2: markdownlint step targets docs/architecture.md and docs/adr/*.md" "pass"
  else
    check "AC2: markdownlint step targets docs/architecture.md and docs/adr/*.md" "fail"
  fi
else
  check "AC2: markdownlint step present in ci.yml" "fail"
fi

# AC3: pixi info step present
if [ -f "$CI_FILE" ] && grep -q "pixi info" "$CI_FILE" && grep -q "pixi.toml" "$CI_FILE"; then
  check "AC3: pixi info --manifest-path pixi.toml step present" "pass"
else
  check "AC3: pixi info --manifest-path pixi.toml step present" "fail"
fi

# AC4: just --summary step present
if [ -f "$CI_FILE" ] && grep -q "just --summary\|just.*--summary" "$CI_FILE"; then
  check "AC4: pixi run just --summary step present" "pass"
else
  check "AC4: pixi run just --summary step present" "fail"
fi

# AC5: symlink integrity step present
if [ -f "$CI_FILE" ] && grep -q "type l" "$CI_FILE"; then
  check "AC5: symlink integrity audit step present" "pass"
else
  check "AC5: symlink integrity audit step present" "fail"
fi

# AC6: verify_claude_read_permissions.py conditional step present
if [ -f "$CI_FILE" ] && grep -q "verify_claude_read_permissions.py" "$CI_FILE"; then
  # Must be conditional (wrapped in if -f check or equivalent)
  if grep -B5 "verify_claude_read_permissions.py" "$CI_FILE" | grep -q "\-f scripts/verify_claude_read_permissions.py\|if \[ -f"; then
    check "AC6: verify_claude_read_permissions.py step is conditional (graceful skip)" "pass"
  else
    check "AC6: verify_claude_read_permissions.py step is conditional (graceful skip)" "fail"
  fi
else
  check "AC6: verify_claude_read_permissions.py step present in ci.yml" "fail"
fi

# AC7: harden job has timeout-minutes: 10 and runs-on: ubuntu-latest
if [ -f "$CI_FILE" ]; then
  # Extract harden job block (lines from harden: to next top-level job or EOF)
  harden_block=$(awk '/^  harden:/{found=1} found{print} /^  [a-zA-Z]/{if(found && !/^  harden:/){exit}}' "$CI_FILE")
  if echo "$harden_block" | grep -q "timeout-minutes: 10" && echo "$harden_block" | grep -q "ubuntu-latest"; then
    check "AC7: harden job has timeout-minutes: 10 and runs-on: ubuntu-latest" "pass"
  else
    check "AC7: harden job has timeout-minutes: 10 and runs-on: ubuntu-latest" "fail"
  fi
else
  check "AC7: harden job has timeout-minutes: 10 and runs-on: ubuntu-latest" "fail"
fi

# AC7b: harden job uses actions/checkout@v4 and setup-pixi
if [ -f "$CI_FILE" ]; then
  harden_block=$(awk '/^  harden:/{found=1} found{print} /^  [a-zA-Z]/{if(found && !/^  harden:/){exit}}' "$CI_FILE")
  if echo "$harden_block" | grep -q "actions/checkout@v4" && echo "$harden_block" | grep -q "setup-pixi"; then
    check "AC7b: harden job uses actions/checkout@v4 and setup-pixi action" "pass"
  else
    check "AC7b: harden job uses actions/checkout@v4 and setup-pixi action" "fail"
  fi
else
  check "AC7b: harden job uses actions/checkout@v4 and setup-pixi action" "fail"
fi

# AC8: Branch feat/issue-22-ci-hardening exists (local or remote)
if git branch --list "feat/issue-22-ci-hardening" | grep -q "feat/issue-22-ci-hardening" || \
   git branch -r | grep -q "feat/issue-22-ci-hardening"; then
  check "AC8: Branch feat/issue-22-ci-hardening exists" "pass"
else
  check "AC8: Branch feat/issue-22-ci-hardening exists" "fail"
fi

# AC8b: PR exists against main with Closes #22 in body
if command -v gh &>/dev/null; then
  pr_body=$(gh pr list --base main --head feat/issue-22-ci-hardening --json body --jq '.[0].body' 2>/dev/null || echo "")
  if echo "$pr_body" | grep -qi "closes #22"; then
    check "AC8b: PR against main with 'Closes #22' in body exists" "pass"
  else
    # Also check if PR exists at all
    pr_count=$(gh pr list --base main --head feat/issue-22-ci-hardening --json number --jq 'length' 2>/dev/null || echo "0")
    if [ "$pr_count" -gt 0 ]; then
      check "AC8b: PR against main with 'Closes #22' in body exists (PR exists but body missing 'Closes #22')" "fail"
    else
      check "AC8b: PR against main from feat/issue-22-ci-hardening exists" "fail"
    fi
  fi
else
  check "AC8b: gh CLI not available to verify PR" "fail"
fi

# AC9: Auto-merge enabled on PR
if command -v gh &>/dev/null; then
  auto_merge=$(gh pr list --base main --head feat/issue-22-ci-hardening --json autoMergeRequest --jq '.[0].autoMergeRequest' 2>/dev/null || echo "null")
  if [ "$auto_merge" != "null" ] && [ -n "$auto_merge" ]; then
    check "AC9: Auto-merge enabled on PR" "pass"
  else
    check "AC9: Auto-merge enabled on PR (autoMergeRequest is null or PR not found)" "fail"
  fi
else
  check "AC9: gh CLI not available to verify auto-merge" "fail"
fi

# AC10: validate job unchanged (yamllint on configs/ still present)
if [ -f "$CI_FILE" ]; then
  if grep -q "validate:" "$CI_FILE" && grep -q "yamllint" "$CI_FILE" && grep -q "configs/" "$CI_FILE"; then
    check "AC10: validate job with yamllint on configs/ is present and unchanged" "pass"
  else
    check "AC10: validate job with yamllint on configs/ is present and unchanged" "fail"
  fi
else
  check "AC10: ci.yml exists for validate job check" "fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
```