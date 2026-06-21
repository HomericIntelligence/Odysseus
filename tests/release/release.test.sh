#!/usr/bin/env bash
# tests/release/release.test.sh — release pipeline regression tests
set -euo pipefail
cd "$(dirname "$0")/../.."

test_count=0; pass_count=0
pass() { echo "PASS: $1"; pass_count=$((pass_count + 1)); test_count=$((test_count + 1)); }
fail() { echo "FAIL: $1"; test_count=$((test_count + 1)); }

# 1. semver tag regex accepts/rejects correctly
for good in v0.1.0 v1.2.3 v10.0.1; do
  [[ $good =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && pass "tag '$good' valid" || fail "tag '$good' should be valid"
done
for bad in v1.0.0-alpha 1.0.0 v1.0 version-1.0.0; do
  [[ $bad =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && fail "tag '$bad' should be invalid" || pass "tag '$bad' rejected"
done

# 2. CHANGELOG structure
grep -q "^## \[Unreleased\]$" CHANGELOG.md && pass "CHANGELOG has [Unreleased]" || fail "missing [Unreleased]"
grep -qE "^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md \
  && pass "CHANGELOG has a dated release section" || fail "no dated section"

# 3. [Unreleased] footer is a compare/<base>...HEAD form (matches the CHANGELOG edit verbatim)
grep -qE "^\[Unreleased\]: https://github.com/HomericIntelligence/Odysseus/compare/[0-9a-fv.]+\.\.\.HEAD$" CHANGELOG.md \
  && pass "CHANGELOG [Unreleased] footer is compare/...HEAD form" || fail "missing/!compare [Unreleased] footer"

# 4. footer references NO phantom v-tags (zero tags exist in repo)
if grep -qE "releases/tag/v[0-9]|compare/v[0-9]" CHANGELOG.md; then
  fail "CHANGELOG references phantom v-tag URLs (no tags exist yet)"
else
  pass "no phantom v-tag URLs in CHANGELOG"
fi

# 5. consistency script pre-commit mode passes on current tree
python3 scripts/check_version_consistency.py >/dev/null && pass "version consistency (pre-commit mode) OK" || fail "consistency script failed"

# 6. note-extraction does NOT bleed the link-reference footer into release notes
tmp_out="$(mktemp)"; tmp_changelog="$(mktemp)"
cat > "$tmp_changelog" <<'EOF'
## [Unreleased]

### Added
- pending

## [9.9.9] - 2026-01-01

### Added
- shipped feature

[Unreleased]: https://github.com/HomericIntelligence/Odysseus/compare/b10bfdd...HEAD
[9.9.9]: https://github.com/HomericIntelligence/Odysseus/releases/tag/v9.9.9
EOF
VERSION=9.9.9 CHANGELOG_PATH="$tmp_changelog" GITHUB_OUTPUT="$tmp_out" \
  python3 scripts/extract_release_notes.py \
  && notes_file="$(grep -oP 'notes_file=\K.*' "$tmp_out")" \
  && body="$(cat "$notes_file")" \
  && { ! echo "$body" | grep -qE "compare/|releases/tag/"; } \
  && pass "release notes do not absorb the link-ref footer" \
  || fail "footer bled into release notes"
rm -f "$tmp_out" "$tmp_changelog"

echo ""; echo "Results: ${pass_count}/${test_count} tests passed"
[ "$pass_count" -eq "$test_count" ]
