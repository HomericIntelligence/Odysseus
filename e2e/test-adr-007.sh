#!/usr/bin/env bash
set -euo pipefail

# ADR-007 Validation Script
# Runs ~45 checks across 7 acceptance criteria against docs/adr/007-symlinks-over-submodules.md

ADR_FILE="docs/adr/007-symlinks-over-submodules.md"
PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_grep() {
    local desc="$1"; local pattern="$2"
    if grep -qiE "$pattern" "$ADR_FILE" 2>/dev/null; then pass "$desc"; else fail "$desc"; fi
}

# ═════════════════════════���═══════════════════════════════════���═════
echo "=== Criterion 1: File existence ==="
# ═══════════════════════════════════════════════════════════════════

if [ ! -f "$ADR_FILE" ]; then
    fail "File exists at $ADR_FILE"
    echo ""
    echo "FATAL: ADR file not found. Cannot continue."
    echo "Result: 0 passed, 1 failed"
    exit 1
fi
pass "File exists at $ADR_FILE"

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 2: Status field ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "Status field is present" '^\*\*Status:\*\*'
check_grep "Status is Proposed or Accepted" '^\*\*Status:\*\* (Proposed|Accepted)'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 3: Context content ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "Mentions 15 submodule entries" '15.*(submodule|entries|submodules)'
check_grep "Mentions 12 are symlinks" '12.*(symlink|symlinks|mode.*120000)'
check_grep "Mentions 3 are real gitlinks" '3.*(gitlink|real|mode.*160000|proper)'
check_grep "Mentions cloning is broken" '[Cc]lon(e|ing)'
check_grep "Mentions CI/CD is broken" 'CI(/|-)CD'
check_grep "Mentions onboarding is broken" '[Oo]nboard'
check_grep "Mentions disaster recovery" '[Dd]isaster.*(recovery|recoverable)'
check_grep "Mentions absolute local paths" '(absolute|local).*(path|director)'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 4: Decision content ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "Documents conversion workflow (git rm + submodule add)" 'git rm|git submodule add'
check_grep "Portability rationale" '[Pp]ortab(le|ility)'
check_grep "Covers myrmidons with submodules" '[Mm]yrmidon'
check_grep "Covers worktrees with submodules" '[Ww]orktree'
check_grep "Covers sub-agents with submodules" '[Ss]ub.agent|[Cc]laude.*(Code|agent)|isolation.*worktree'
check_grep "Task scoping principle documented" '[Tt]ask.*(scop|priorit)|[Rr]epo.*(level|execute)|Odysseus.*coordinate'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 5: Consequences ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "Positive: clone works" '[Pp]ositive|clone.*works|out of the box'
check_grep "Positive: CI/CD works" 'CI.*pipeline|pipeline.*work|container.*work'
check_grep "Positive: onboarding works" 'onboard|single clone'
check_grep "Positive: disaster recovery" 'reconstit|disaster|recoverable'
check_grep "Negative: lost symlink convenience" 'convenience|symlinked.*local|lose'
check_grep "Negative: extra update step" 'submodule update|extra.*step|additional.*step'
check_grep "Neutral section has substance" '^\*\*Neutral:\*\*'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 6: Format compliance ==="
# ═══════════════════════════════════════════════════════════════════

# H1 title with ADR number
LINE1=$(head -1 "$ADR_FILE")
if echo "$LINE1" | grep -qE '^# ADR 007:'; then pass "H1 title starts with '# ADR 007:'"; else fail "H1 title starts with '# ADR 007:'"; fi

# Title is on line 1
if [ "$(sed -n '1p' "$ADR_FILE" | grep -c '^# ')" -eq 1 ]; then pass "Title is on line 1"; else fail "Title is on line 1"; fi

# Status near top (within first 5 lines)
if head -5 "$ADR_FILE" | grep -qE '^\*\*Status:\*\*'; then pass "Status within first 5 lines"; else fail "Status within first 5 lines"; fi

# Horizontal rule divider
check_grep "Horizontal rule divider present" '^---$'

# H2 Context section
check_grep "H2 Context section exists" '^## Context'

# H2 Decision section
check_grep "H2 Decision section exists" '^## Decision'

# H2 Consequences section
check_grep "H2 Consequences section exists" '^## Consequences'

# Section order: Context before Decision before Consequences
CTX_LINE=$(grep -n '^## Context' "$ADR_FILE" | head -1 | cut -d: -f1)
DEC_LINE=$(grep -n '^## Decision' "$ADR_FILE" | head -1 | cut -d: -f1)
CON_LINE=$(grep -n '^## Consequences' "$ADR_FILE" | head -1 | cut -d: -f1)
if [ -n "$CTX_LINE" ] && [ -n "$DEC_LINE" ] && [ -n "$CON_LINE" ] && \
   [ "$CTX_LINE" -lt "$DEC_LINE" ] && [ "$DEC_LINE" -lt "$CON_LINE" ]; then
    pass "Section order: Context < Decision < Consequences"
else
    fail "Section order: Context < Decision < Consequences"
fi

# Positive/Negative/Neutral subsection headers
check_grep "Positive subsection header" '^\*\*Positive:\*\*'
check_grep "Negative subsection header" '^\*\*Negative:\*\*'
check_grep "Neutral subsection header" '^\*\*Neutral:\*\*'

# ═══════════════════════════════════════════════════════════════════
echo "=== Criterion 7: Factual accuracy ==="
# ═══════════════════════════════════════════════════════════════════

check_grep "Mentions 15 total submodules" '15'
check_grep "Mentions 12 symlinks" '12'
check_grep "Mentions 3 gitlinks" '\b3\b.*(gitlink|real|proper|correct)'

# Check for specific symlinked repo names
check_grep "Mentions AchaeanFleet" 'AchaeanFleet'
check_grep "Mentions ProjectArgus" 'ProjectArgus'
check_grep "Mentions ProjectHermes" 'ProjectHermes'
check_grep "Mentions ProjectScylla" 'ProjectScylla'
check_grep "Mentions ProjectHephaestus" 'ProjectHephaestus'

# Check for the 3 gitlink repos
check_grep "Mentions ProjectAgamemnon as gitlink" 'ProjectAgamemnon'
check_grep "Mentions ProjectNestor as gitlink" 'ProjectNestor'
check_grep "Mentions ProjectCharybdis as gitlink" 'ProjectCharybdis'

# .gitmodules note
check_grep "Notes .gitmodules URLs are correct" '\.gitmodules.*(no change|correct|already|require.*no)'

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════��════"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Result: $PASS_COUNT passed, $FAIL_COUNT failed (out of $TOTAL checks)"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
else
    echo "ALL CHECKS PASSED"
    exit 0
fi
