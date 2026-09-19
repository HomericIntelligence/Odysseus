#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scripts/check-doc-field-drift.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# Shared tracked-file reader must reject a deterministic regular-to-symlink
# swap at the actual open boundary before either documentation gate uses it.
python3 "$repo_root/scripts/tracked_scan.py" --self-test

git -C "$fixture" init -q
printf '%s\n' 'No deprecated workflow field here.' > "$fixture/deleted.md"
git -C "$fixture" add deleted.md
rm -- "$fixture/deleted.md"

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 0 )); then
    printf 'FAIL: tracked worktree deletion returned %d\n%s\n' "$status" "$output" >&2
    exit 1
fi
if [[ "$output" == *"No such file or directory"* ]]; then
    printf 'FAIL: tracked worktree deletion was passed to grep\n%s\n' "$output" >&2
    exit 1
fi

printf '%s\n' '- title: deprecated' > "$fixture/active.md"
git -C "$fixture" add active.md

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 1 )); then
    printf 'FAIL: deprecated live field returned %d instead of 1\n%s\n' "$status" "$output" >&2
    exit 1
fi

git -C "$fixture" rm -q -f active.md
printf '%s\n' 'safe' > "$fixture/replaced.md"
git -C "$fixture" add replaced.md
rm -- "$fixture/replaced.md"
ln -s missing.md "$fixture/replaced.md"

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 2 )); then
    printf 'FAIL: tracked symlink type change returned %d instead of 2\n%s\n' \
        "$status" "$output" >&2
    exit 1
fi

git -C "$fixture" rm -q -f replaced.md
newline_path=$'odd\nname.md'
printf '%s\n' '- depends_on: deprecated' > "$fixture/$newline_path"
git -C "$fixture" add "$newline_path"

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 1 )); then
    printf 'FAIL: newline-bearing tracked path returned %d instead of 1\n%s\n' \
        "$status" "$output" >&2
    exit 1
fi

git -C "$fixture" rm -q -f -- "$newline_path"
option_path='--exclude=*.md'
printf '%s\n' '- title: deprecated' > "$fixture/$option_path"
git -C "$fixture" add -- "$option_path"

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 1 )); then
    printf 'FAIL: leading-option tracked path returned %d instead of 1\n%s\n' \
        "$status" "$output" >&2
    exit 1
fi

git -C "$fixture" rm -q -f -- "$option_path"
printf '%s\n' '- "title" : deprecated' > "$fixture/quoted-title.md"
printf '%s\n' "  'depends_on'  : deprecated" > "$fixture/quoted-dependency.md"
git -C "$fixture" add quoted-title.md quoted-dependency.md

set +e
output="$(cd "$fixture" && "$checker" 2>&1)"
status=$?
set -e

if (( status != 1 )); then
    printf 'FAIL: quoted deprecated keys returned %d instead of 1\n%s\n' \
        "$status" "$output" >&2
    exit 1
fi

# A broken checker installation is an operational failure, never a drift
# finding. Run a copy without its required shared reader to exercise import
# failure independently of the repository-owned script directory.
broken_checker="$fixture/check-doc-field-drift.sh"
cp "$checker" "$broken_checker"
chmod +x "$broken_checker"

set +e
output="$(cd "$fixture" && "$broken_checker" 2>&1)"
status=$?
set -e

if (( status != 2 )); then
    printf 'FAIL: missing tracked_scan returned %d instead of 2\n%s\n' \
        "$status" "$output" >&2
    exit 1
fi
if [[ "$output" == *"deprecated workflow field name(s) found"* ]]; then
    printf 'FAIL: operational import failure was mislabeled as drift\n%s\n' \
        "$output" >&2
    exit 1
fi

echo 'PASS: document-field gate handles deletions, drift, type changes, and unusual paths'
