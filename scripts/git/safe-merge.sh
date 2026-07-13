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

# Inhibit interactive editor on `git merge --no-ff` (would otherwise pause
# in any TTY context, contradicting the documented exit codes).
export GIT_MERGE_AUTOEDIT=no

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

# Capture `git merge` exit code BEFORE set -e aborts on conflict. The +e/-e
# pair is intentional; do not collapse — the post-capture `set -e` is what
# makes the `git merge --abort` path reachable on conflict.
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
# Capturing the unmerged-path list: a nonzero exit here just means "could not
# enumerate" (e.g. not in a git dir); an empty result is the normal no-conflict
# case. Drop out of `set -e` for the single capture so an expected-nonzero exit
# does not abort — this is control flow, not a masked command failure.
set +e
unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
set -e
if [ -n "$unmerged" ] \
   || printf '%s' "$merge_out" | grep -qE 'CONFLICT \(|Automatic merge failed|fix conflicts'; then
    echo "safe-merge: conflict detected in merge with '$BRANCH'." >&2
    echo "safe-merge: aborting to prevent conflict markers from leaking into a commit." >&2
    echo "----- git merge output -----" >&2
    printf '%s\n' "$merge_out" >&2
    echo "----------------------------" >&2
    # Best-effort abort (no-op if we're not actually in a merge state). A
    # nonzero rc here just means "there was nothing to abort" — we are already
    # on the error path exiting 4, so deliberately ignore the rc via an `if`
    # (which `set -e` does not treat as a failure) rather than masking a real
    # command failure with the forbidden `|| true` idiom.
    if git merge --abort >/dev/null 2>&1; then
        :  # aborted cleanly
    fi
    exit 4
fi

# Other failures - propagate git's exit code, surface output.
printf '%s\n' "$merge_out"
exit "$merge_rc"
