#!/usr/bin/env bash
# Check the pinned analyzer on executable function-order examples.
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/defined.sh" <<'SCRIPT'
#!/usr/bin/env bash
first() { echo first; }
second() { echo second; }
main() {
    echo "$(first)"
    first
    echo "$(second)"
}
main
SCRIPT

# ShellCheck 0.11 incorrectly rejects this shape (upstream issue #3290).
bash "$scratch/defined.sh" > "$scratch/output"
printf 'first\nfirst\nsecond\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/output"
shellcheck --severity=warning "$scratch/defined.sh"
echo 'PASS: defined functions remain valid across command substitutions'

cat > "$scratch/undefined.sh" <<'SCRIPT'
#!/usr/bin/env bash
later
later() { echo later; }
SCRIPT

if shellcheck --severity=warning "$scratch/undefined.sh" > "$scratch/diagnostic"; then
    echo 'FAIL: analyzer accepted a function call before its definition' >&2
    exit 1
fi
grep -q 'SC2218' "$scratch/diagnostic"
echo 'PASS: function calls before their definitions are rejected'
