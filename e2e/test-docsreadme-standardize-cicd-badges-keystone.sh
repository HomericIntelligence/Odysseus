#!/usr/bin/env bash
set -euo pipefail

README="provisioning/ProjectKeystone/README.md"
WORKFLOWS_DIR="provisioning/ProjectKeystone/.github/workflows"
FAIL=0
PASS_COUNT=0
TOTAL=0

check() {
  local desc="$1"
  local result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" -eq 0 ]; then
    echo "PASS: $desc"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $desc"
    FAIL=1
  fi
}

# Check that README exists
if [ ! -f "$README" ]; then
  echo "FAIL: $README does not exist"
  exit 1
fi

# 1. Badge block contains live GitHub Actions badges for the three real workflows
for wf in extras.yml profiling-weekly.yml release-please.yml; do
  badge_pattern="https://github.com/HomericIntelligence/ProjectKeystone/actions/workflows/${wf}/badge.svg"
  link_pattern="https://github.com/HomericIntelligence/ProjectKeystone/actions/workflows/${wf}"
  grep -qF "$badge_pattern" "$README"
  check "Live badge image URL exists for $wf" $?
  grep -qF "$link_pattern" "$README"
  check "Live badge link URL exists for $wf" $?
done

# 2. No badge references mvillmow/ProjectKeystone anywhere in README
if grep -qi "mvillmow/ProjectKeystone" "$README"; then
  check "No references to mvillmow/ProjectKeystone" 1
else
  check "No references to mvillmow/ProjectKeystone" 0
fi

# 3. No badge references nonexistent quality.yml
if grep -qi "quality\.yml" "$README"; then
  check "No references to nonexistent quality.yml" 1
else
  check "No references to nonexistent quality.yml" 0
fi

# 4. Static hardcoded Code Coverage (86.2%) and Tests (481 passing) shields removed
if grep -qi "86\.2" "$README"; then
  check "Static Code Coverage (86.2%) badge removed" 1
else
  check "Static Code Coverage (86.2%) badge removed" 0
fi

if grep -qi "481.*passing\|tests-481" "$README"; then
  check "Static Tests (481 passing) badge removed" 1
else
  check "Static Tests (481 passing) badge removed" 0
fi

# 5. Static C++ Standard and License shields retained
grep -qF "img.shields.io/badge/C++-20" "$README"
check "Static C++ Standard shield retained" $?

grep -qF "img.shields.io/badge/license-MIT" "$README"
check "Static License shield retained" $?

# 6. Each referenced workflow file actually exists in .github/workflows/
for wf in extras.yml profiling-weekly.yml release-please.yml; do
  if [ -f "${WORKFLOWS_DIR}/${wf}" ]; then
    check "Workflow file ${wf} exists in .github/workflows/" 0
  else
    check "Workflow file ${wf} exists in .github/workflows/" 1
  fi
done

# Also verify _required.yml is NOT badged (excluded per issue rules)
if grep -q "actions/workflows/_required.yml/badge.svg" "$README"; then
  check "No badge for _required.yml (aggregator excluded)" 1
else
  check "No badge for _required.yml (aggregator excluded)" 0
fi

# 7. Clone URL references HomericIntelligence/ProjectKeystone
grep -qF "github.com/HomericIntelligence/ProjectKeystone.git" "$README"
check "Clone URL references HomericIntelligence/ProjectKeystone" $?

# Also verify no clone URL still points to mvillmow
if grep -q "git clone.*mvillmow" "$README"; then
  check "No clone URL pointing to mvillmow" 1
else
  check "No clone URL pointing to mvillmow" 0
fi

# 8. No other files modified besides README.md
# Check git diff to ensure only README.md is changed in the submodule
cd provisioning/ProjectKeystone
changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
if [ -z "$changed_files" ]; then
  # No uncommitted changes — check the latest commit
  changed_files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "README.md")
fi
non_readme=$(echo "$changed_files" | grep -v "^README.md$" || true)
if [ -z "$non_readme" ]; then
  check "Only README.md is modified" 0
else
  check "Only README.md is modified (also changed: $non_readme)" 1
fi
cd ../..

# Summary
echo ""
echo "========================================="
echo "Results: $PASS_COUNT/$TOTAL passed"
if [ "$FAIL" -eq 1 ]; then
  echo "STATUS: FAILED"
  exit 1
else
  echo "STATUS: ALL PASSED"
  exit 0
fi
