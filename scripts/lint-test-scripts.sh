#!/usr/bin/env bash
#
# lint-test-scripts.sh — Guard against corrupted / non-runnable test scripts.
#
# Failed-agent-output artifacts have been committed as "tests" before (see
# issue #374): 18 files under e2e/ that were either a single garbage line
# ("ERROR: Claude returned empty output"), markdown-fenced prose, or a chat
# transcript ("It seems bash tool is blocked..."). None of them ran; a `just`
# recipe that invoked them exited 127. This lint would have caught all 18.
#
# For every test script (e2e/test-*.sh and tests/**/*.sh) it asserts:
#   1. Line 1 is a valid shebang (starts with "#!").
#   2. The file does not contain the literal "Claude returned empty output".
#   3. The file has more than 3 non-comment, non-blank lines (non-trivial).
#
# Usage:
#   scripts/lint-test-scripts.sh
#
# Exit codes:
#   0  All discovered test scripts are well-formed.
#   1  One or more test scripts are corrupted / trivial / non-executable.
#
# Used by the Required Checks workflow (.github/workflows/_required.yml) and
# `just lint-test-scripts`.

set -uo pipefail

# Resolve repo root so the script works from any cwd.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GARBAGE_MARKER='Claude returned empty output'

# Collect candidate test scripts. Both patterns are optional; a missing dir is
# not an error (the tree may legitimately lack one).
declare -a FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(
  { find e2e -maxdepth 1 -name 'test-*.sh' -type f 2>/dev/null
    [ -d tests ] && find tests -name '*.sh' -type f 2>/dev/null
  } | sort -u
)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "OK: no test scripts discovered (nothing to lint)."
  exit 0
fi

fail_count=0
for f in "${FILES[@]}"; do
  errors=()

  # 1. Shebang on line 1.
  first_line="$(head -n 1 "$f")"
  case "$first_line" in
    '#!'*) ;;
    *) errors+=("line 1 is not a '#!' shebang (found: ${first_line:0:60})") ;;
  esac

  # 2. No failed-agent-output garbage marker.
  if grep -qF "$GARBAGE_MARKER" "$f"; then
    errors+=("contains failed-agent-output marker: '$GARBAGE_MARKER'")
  fi

  # 3. Non-trivial: > 3 non-comment, non-blank lines.
  substantive="$(grep -cvE '^[[:space:]]*(#|$)' "$f")"
  if [ "$substantive" -le 3 ]; then
    errors+=("only $substantive non-comment lines (trivial / not a real test)")
  fi

  if [ "${#errors[@]}" -gt 0 ]; then
    fail_count=$((fail_count + 1))
    echo "FAIL: $f"
    for e in "${errors[@]}"; do
      echo "    - $e"
    done
  else
    echo "OK:   $f"
  fi
done

echo ""
if [ "$fail_count" -gt 0 ]; then
  echo "lint-test-scripts: $fail_count corrupted / trivial test script(s) found." >&2
  echo "Remove or fix them — test scripts must have a #! shebang, be non-trivial," >&2
  echo "and must not contain failed-agent-output artifacts. See issue #374." >&2
  exit 1
fi

echo "lint-test-scripts: all ${#FILES[@]} test script(s) are well-formed."
exit 0
