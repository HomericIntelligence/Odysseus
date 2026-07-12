#!/usr/bin/env bash
# scripts/git/safe-merge.sh - guarded merge that aborts on conflict.
#
# Replaces ad-hoc `git merge --no-ff <branch>` calls with one that fails
# cleanly when git reports conflicts, instead of leaving conflict-marker
# content in the working tree (the bug that corrupted 0651c1c on
# chore/split-hephaestus-athena).
#
# Usage: scripts/git/safe-merge.sh <upstream-branch>
#
# Exit codes:
#   0 - merge completed cleanly
#   1 - pre-merge working tree dirty (refused to merge)
#   2 - index has staged-but-uncommitted changes (refused to merge)
#   4 - merge conflicted; ran `git merge --abort` for safety
#   * - propagates git merge exit code for non-conflict failures

set -euo pipefail

BRANCH="${1:?usage: $0 <upstream-branch>}"

# Guard 1: refuse to merge into a dirty working tree.
if ! git diff --quiet HEAD; then
    echo "safe-merge: working tree has unstaged changes; commit or stash first" >&2
    git status --short >&2
    exit 1
fi

# Guard 2: refuse to merge with staged-but-not-committed changes that would
# muddle the resulting commit.
if ! git diff --quiet --cached; then
    echo "safe-merge: index has staged changes; commit them first" >&2
    git diff --cached --stat >&2
    exit 2
fi

# Run the merge. Capture stdout/stderr so we can inspect for conflict signals
# after git's own exit code.
set +e
merge_out="$(git merge --no-ff "$BRANCH" 2>&1)"
merge_rc=$?
set -e

# If git exit code is 0, the merge succeeded with no conflicts.
if [ "$merge_rc" -eq 0 ]; then
    printf '%s\n' "$merge_out"
    exit 0
fi

# Detect conflict: either we have unmerged paths, or git's output mentions
# CONFLICT / Automatic merge failed.
unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
if [ -n "$unmerged" ] \
   || printf '%s' "$merge_out" | grep -qE 'CONFLICT \(|Automatic merge failed|fix conflicts'; then
    echo "safe-merge: conflict detected in merge with '$BRANCH'." >&2
    echo "safe-merge: aborting to prevent conflict markers from leaking into a commit." >&2
    echo "----- git merge output -----" >&2
    printf '%s\n' "$merge_out" >&2
    echo "----------------------------" >&2
    # Best-effort abort (no-op if we're not actually in a merge state).
    git merge --abort >/dev/null 2>&1 || true
    exit 4
fi

# Other failures - propagate git's exit code, surface output.
printf '%s\n' "$merge_out"
exit "$merge_rc"
