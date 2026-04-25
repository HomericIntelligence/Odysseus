```bash
#!/usr/bin/env bash

PASS=0
FAIL=0
CI_FILE=".github/workflows/ci.yml"

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    ((FAIL++))
  fi
}

file_exists() {
  [ -f "$CI_FILE" ]
  check "CI workflow file exists at $CI_FILE" $?
}

file_exists

# AC1: markdownlint-cli install step
grep -q 'npm install -g markdownlint-cli' "$CI_FILE" 2>/dev/null
check "AC1a: markdownlint-cli installed via npm" $?

grep -q "markdownlint docs/architecture.md docs/adr/\*\.md" "$CI_FILE" 2>/dev/null
check "AC1b: markdownlint runs on docs/architecture.md docs/adr/*.md" $?

# AC2: pixi validity step
grep -q 'prefix-dev/setup-pixi@v0\.8\.1' "$CI_FILE" 2>/dev/null
check "AC2a: uses prefix-dev/setup-pixi@v0.8.1" $?

grep -q 'run-install: false' "$CI_FILE" 2>/dev/null
check "AC2b: setup-pixi has run-install: false" $?

grep -q 'pixi info --manifest-path pixi\.toml' "$CI_FILE" 2>/dev/null
check "AC2c: pixi info --manifest-path pixi.toml step present" $?

# AC3: just install and parse step
grep -q 'just\.systems/install\.sh' "$CI_FILE" 2>/dev/null
check "AC3a: just installed via official install script" $?

grep -q 'just --summary' "$CI_FILE" 2>/dev/null
check "AC3b: just --summary step present" $?

# AC4: symlink integrity step
grep -q 'find \. -type l' "$CI_FILE" 2>/dev/null
check "AC4a: find . -type l present in workflow" $?

grep -q '\[ ! -e.*\$link' "$CI_FILE" 2>/dev/null || grep -q '! -e "\$link"' "$CI_FILE" 2>/dev/null
check "AC4b: broken symlink check [ ! -e \"\$link\" ] present" $?

grep -q 'BROKEN:' "$CI_FILE" 2>/dev/null
check "AC4c: prints BROKEN: for broken symlinks" $?

# AC5: conditional script step
grep -q 'if \[ -f scripts/verify_claude_read_permissions\.py \]' "$CI_FILE" 2>/dev/null
check "AC5a: conditional check for scripts/verify_claude_read_permissions.py present" $?

grep -q 'python3 scripts/verify_claude_read_permissions\.py' "$CI_FILE" 2>/dev/null
check "AC5b: runs verify_claude_read_permissions.py if present" $?

grep -q 'skipping' "$CI_FILE" 2>/dev/null
check "AC5c: prints skip message when script absent" $?

# AC6: original yamllint step preserved
grep -q 'yamllint' "$CI_FILE" 2>/dev/null
check "AC6a: original yamllint step preserved" $?

grep -q "find configs/" "$CI_FILE" 2>/dev/null
check "AC6b: yamllint runs on configs/ directory" $?

grep -q 'pip install yamllint' "$CI_FILE" 2>/dev/null
check "AC6c: yamllint install step preserved" $?

# AC7: branch name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$CURRENT_BRANCH" = "feat/issue-22-ci-hardening" ]
check "AC7: current branch is feat/issue-22-ci-hardening (got: $CURRENT_BRANCH)" $?

# AC8: commit message
LAST_COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null)
[ "$LAST_COMMIT_MSG" = "fix(ci): extend CI workflow with markdownlint, pixi, justfile, and symlink checks (#22)" ]
check "AC8: last commit message matches exactly (got: $LAST_COMMIT_MSG)" $?

# AC9: PR body contains Closes #22
PR_BODY=$(gh pr view --json body -q .body 2>/dev/null)
echo "$PR_BODY" | grep -q 'Closes #22'
check "AC9: PR body contains 'Closes #22'" $?

# AC10: auto-merge enabled
AUTO_MERGE=$(gh pr view --json autoMergeRequest -q '.autoMergeRequest' 2>/dev/null)
[ -n "$AUTO_MERGE" ] && [ "$AUTO_MERGE" != "null" ]
check "AC10: auto-merge is enabled on the PR" $?

# AC11: CI jobs pass on PR
PR_STATUS=$(gh pr checks 2>/dev/null)
echo "$PR_STATUS" | grep -q 'validate'
check "AC11a: validate job exists in PR checks" $?

echo "$PR_STATUS" | grep -q 'verify-scripts'
check "AC11b: verify-scripts job exists in PR checks" $?

FAILING=$(echo "$PR_STATUS" | grep -E 'fail|error' | grep -v 'grep' | wc -l)
[ "$FAILING" -eq 0 ]
check "AC11c: no failing CI checks on PR" $?

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```