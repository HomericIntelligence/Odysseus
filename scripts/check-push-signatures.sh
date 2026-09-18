#!/usr/bin/env bash
# Verify the complete, deduplicated commit set for every ref in a pre-push event.
set -euo pipefail

ZERO_SHA=0000000000000000000000000000000000000000
COMMITS_TO_CHECK=()
SAW_PUSH_REF=false
REMOTE_NAME="${1:-}"
REMOTE_LOCATION="${2:-}"
DESTINATION_TIPS=()
DESTINATION_SNAPSHOT_LOADED=false

default_remote_ref() {
    local resolved
    if resolved=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
        printf '%s\n' "${resolved#refs/remotes/}"
    else
        printf '%s\n' origin/main
    fi
}

add_range() {
    add_revisions "$1"
}

add_revisions() {
    local commits sha known duplicate
    commits=$(git rev-list "$@")
    for sha in $commits; do
        duplicate=false
        for known in "${COMMITS_TO_CHECK[@]-}"; do
            if [[ "$known" == "$sha" ]]; then
                duplicate=true
                break
            fi
        done
        if [[ "$duplicate" == false ]]; then
            COMMITS_TO_CHECK+=("$sha")
        fi
    done
}

load_destination_tips() {
    local listing line sha remote_ref extra known duplicate
    if [[ "$DESTINATION_SNAPSHOT_LOADED" == true ]]; then
        return 0
    fi
    if [[ -z "$REMOTE_NAME" || -z "$REMOTE_LOCATION" ]]; then
        echo "ERROR: pre-push remote identity is required for a new ref" >&2
        exit 1
    fi
    if ! listing=$(git ls-remote --refs -- "$REMOTE_LOCATION"); then
        echo "ERROR: could not snapshot destination refs for $REMOTE_NAME" >&2
        exit 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r sha remote_ref extra <<< "$line"
        if [[ -n "${extra:-}" \
              || ! "$sha" =~ ^[0-9a-fA-F]{40}$ \
              || ! "$remote_ref" =~ ^refs/[^[:space:]]+$ ]]; then
            echo "ERROR: destination ref snapshot is malformed" >&2
            exit 1
        fi
        duplicate=false
        for known in "${DESTINATION_TIPS[@]-}"; do
            if [[ "$known" == "$sha" ]]; then
                duplicate=true
                break
            fi
        done
        if [[ "$duplicate" == false ]]; then
            DESTINATION_TIPS+=("$sha")
        fi
    done <<< "$listing"
    DESTINATION_SNAPSHOT_LOADED=true
}

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha extra; do
    SAW_PUSH_REF=true
    if [[ -n "${extra:-}" || -z "${local_ref:-}" || -z "${local_sha:-}" || \
          -z "${remote_ref:-}" || -z "${remote_sha:-}" ]]; then
        echo "ERROR: malformed pre-push ref record" >&2
        exit 1
    fi
    if [[ "$local_sha" == "$ZERO_SHA" ]]; then
        continue
    fi

    if [[ "$remote_sha" == "$ZERO_SHA" ]]; then
        # A new remote ref has no destination commit from which to derive an
        # exact range.  Exclude only commit OIDs observed at the real
        # destination.  Local remote-tracking refs are mutable and may be stale
        # or forged, so they are never an authority for signature coverage.
        load_destination_tips
        if (( ${#DESTINATION_TIPS[@]} > 0 )); then
            add_revisions "$local_sha" --not "${DESTINATION_TIPS[@]}"
        else
            add_revisions "$local_sha"
        fi
    else
        add_range "$remote_sha..$local_sha"
    fi
done

if [[ "$SAW_PUSH_REF" != true ]]; then
    if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        add_range "$upstream..HEAD"
    else
        default_ref=$(default_remote_ref)
        if ! base=$(git merge-base HEAD "$default_ref" 2>/dev/null); then
            add_revisions HEAD
        else
            add_range "$base..HEAD"
        fi
    fi
fi

failed=()
for sha in "${COMMITS_TO_CHECK[@]-}"; do
    [[ -n "$sha" ]] || continue
    if ! status=$(git log -1 --format='%G?' "$sha"); then
        echo "ERROR: could not verify the signature for commit $sha" >&2
        exit 1
    fi
    case "$status" in
        G|U) ;;
        *) failed+=("$sha($status)") ;;
    esac
done

if (( ${#failed[@]} > 0 )); then
    echo "ERROR: unsigned or invalid-signature commits in push range:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    echo >&2
    echo "Repair an unpublished branch by re-signing its commits from a verified base:" >&2
    echo '  git rebase --exec "git commit --amend --no-edit -S" <verified-base>' >&2
    echo >&2
    echo "If these commits are already published, create a replacement branch" >&2
    echo "from the authoritative base, recreate or cherry-pick the changes with" >&2
    echo "signed commits, open a replacement pull request, and link the superseded" >&2
    echo "pull request. Do not bypass hooks or rewrite remote history." >&2
    exit 1
fi
