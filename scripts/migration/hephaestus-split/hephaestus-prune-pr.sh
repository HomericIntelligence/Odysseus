#!/usr/bin/env bash
#
# hephaestus-prune-pr.sh — Phase B of the ProjectHephaestus split (ADR-016)
# ----------------------------------------------------------------------
#
# Companion to tools/github/rename-repo.sh. After Phase A renamed
# HomericIntelligence/ProjectHephaestus → HomericIntelligence/Hephaestus
# on GitHub, this script:
#
#   1. Clones HomericIntelligence/Hephaestus fresh into a temp workdir
#   2. Creates branch chore/remove-athena-surface (idempotent)
#   3. Removes the agent-host plugin/skill surface ADR-016 carves out
#      to a new sibling repo `Athena`:
#        .claude-plugin/  .codex-plugin/  .agents/  plugins/  skills/  assets/
#   4. Rewrites internal ProjectHephaestus → Hephaestus refs and
#      the pyproject/pixi distribution name
#   5. Refuses to commit if any residual old-name string or carve-out
#      path survives
#   6. After a y/N confirmation, pushes the branch and opens a PR
#
# Refuses to run if Phase A (the GitHub-side rename) is not complete.
# Defaults match ADR-016 + docs/runbooks/rename-and-split.md. Don't edit
# the carve-out list without revising ADR-016 first.

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────
ORG="HomericIntelligence"
OLD_REPO="ProjectHephaestus"   # for the negative sanity check
NEW_REPO="Hephaestus"
BRANCH="chore/remove-athena-surface"
PR_TITLE="chore(hephaestus): drop agent-host plugin/skill surface (→ Athena) per ADR-016"

# Carve-out paths: agent-host plugin/skill surface moving to Athena.
# Source of truth: ADR-016 Decision section + docs/runbooks/rename-and-split.md §3.
CARVE_OUT=(.claude-plugin .codex-plugin .agents plugins skills assets)

DRY_RUN=0
NO_PR=0
KEEP_WORKDIR=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [flags]

Phase B of the ProjectHephaestus → Hephaestus + Athena split. Run AFTER
Phase A (gh repo rename) has completed on GitHub.

Flags:
    --dry-run        Print every command that would run; do not write.
    --no-pr          Commit + push only; skip gh pr create.
    --keep-workdir   Leave /tmp/hephaestus-prune-* on exit (for inspection).
    --branch NAME    Override the feature branch (default: $BRANCH).
    --help           Show this help.
USAGE
}

die()  { printf '  ERROR  %s\n' "$*" >&2; exit 1; }
note() { printf '  ----   %s\n' "$*"; }
ok()   { printf '  OK     %s\n' "$*"; }

# ─── Argument parsing ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=1; shift ;;
        --no-pr)         NO_PR=1; shift ;;
        --keep-workdir)  KEEP_WORKDIR=1; shift ;;
        --branch)        BRANCH="${2:-}"; shift 2 || die "--branch requires a name" ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "Unknown argument: $1 (try --help)" ;;
    esac
done

# Branch validation: chars allowed by git refnames; deliberately excludes
# the chars git itself rejects (' ', ':', '?', '*', '[', '~', '^', '\\').
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--branch '$BRANCH' has illegal characters"

# Cleanup the workdir unless the operator asked to keep it.
trap '[ "${KEEP_WORKDIR:-0}" -eq 0 ] && rm -rf "${WORK:-}"' EXIT

# ─── Preflight ───────────────────────────────────────────────────
note "Preflight: gh CLI + auth"
gh --version >/dev/null                || die "gh CLI not installed"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh not authenticated -- run 'gh auth login' first"

note "Preflight: Phase A (rename) state"
gh repo view "$ORG/$NEW_REPO" --json name >/dev/null 2>&1 \
    || die "$ORG/$NEW_REPO does not exist. Run Phase A first: gh repo rename Hephaestus --repo $ORG/$OLD_REPO --confirm"

# Detect Phase A via GitHub's rename-redirect semantics: when a repo is
# renamed, the old slug URL still resolves -- but the response's `name`
# field is the *current* canonical name. Only die if the old name is
# itself still the canonical name (i.e. rename did not actually happen).
OLD_NAME="$(gh repo view "$ORG/$OLD_REPO" --json name --jq '.name' 2>/dev/null || printf '')"
case "$OLD_NAME" in
    "$NEW_REPO")
        note "Phase A confirmed via GitHub redirect: old URL $ORG/$OLD_REPO now serves $ORG/$NEW_REPO"
        ;;
    "$OLD_REPO")
        die "$ORG/$OLD_REPO still exists as the canonical name -- Phase A rename did not complete (or was reverted). Run: gh repo rename Hephaestus --repo $ORG/$OLD_REPO --confirm"
        ;;
    "")
        die "Old URL $ORG/$OLD_REPO fails to resolve -- Phase A status unclear; check the org manually"
        ;;
    *)
        note "Phase A in unexpected state: $ORG/$OLD_REPO returns canonical name '${OLD_NAME}' -- proceeding"
        ;;
esac
ok "Phase A checks passed"

# ─── Working directory ───────────────────────────────────────────
WORK="$(mktemp -d -t hephaestus-prune.XXXXXX)"
note "Workdir: $WORK"

DEFAULT_BRANCH=""
if [[ $DRY_RUN -eq 0 ]]; then
    note "Cloning $ORG/$NEW_REPO"
    gh repo clone "$ORG/$NEW_REPO" "$WORK/$NEW_REPO" 2>&1 | tail -3
    cd "$WORK/$NEW_REPO"

    DEFAULT_BRANCH="$(gh repo view "$ORG/$NEW_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')"
    [[ -n "$DEFAULT_BRANCH" ]] || die "Could not resolve default branch for $ORG/$NEW_REPO"

    # Branch-create idempotent: existing local ref → use it; absent → create from default
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        note "Branch $BRANCH exists locally -- using it"
        git checkout "$BRANCH"
    else
        note "Creating branch $BRANCH off $DEFAULT_BRANCH"
        git checkout -b "$BRANCH"
    fi

    # Dirty-worktree guard: refuse to overwrite local edits.
    if [[ -n "$(git status --porcelain 2>/dev/null || printf '')" ]]; then
        KEEP_WORKDIR=1
        die "Working tree has uncommitted changes; clean (or stash) and re-run."
    fi
else
    note "(dry-run) would: clone $ORG/$NEW_REPO + checkout -b $BRANCH"
fi

# ─── Phase 4: prune carve-out paths ──────────────────────────────
note "Phase 4 — remove carve-out paths"
if [[ $DRY_RUN -eq 0 ]]; then
    for path in "${CARVE_OUT[@]}"; do
        if [[ -e "$path" ]]; then
            note "  git rm -rf $path"
            git rm -rf "$path" >/dev/null
        else
            note "  (skip) $path -- not present"
        fi
    done
    ok "Carve-out paths removed"
else
    note "(dry-run) would: git rm -rf ${CARVE_OUT[*]}"
fi

# ─── Phase 5: sed pipeline (ProjectHephaestus → Hephaestus) ─────
note "Phase 5 — internal ref rename"
if [[ $DRY_RUN -eq 0 ]]; then
    find . -type f \
        ! -path './.git/*' \
        ! -name '*.png'  ! -name '*.jpg'  ! -name '*.gif'  ! -name '*.ico' \
        ! -name '*.webp' \
        ! -name '*.woff*' ! -name '*.ttf' \
        ! -name '*.lock' \
        -print0 | xargs -0 -r sed -i \
            -e 's/ProjectHephaestus/Hephaestus/g' \
            -e 's/project-hephaestus/hephaestus/g'
    ok "Sed pipeline ran"

    note "  Distribution name update (pyproject + pixi)"
    sed -i 's/name = "project-hephaestus"/name = "hephaestus"/' pyproject.toml
    if [[ -f pixi.toml ]]; then
        sed -i 's/name = "project-hephaestus"/name = "hephaestus"/' pixi.toml
    fi
fi

# ─── Phase 6: pre-commit guard ──────────────────────────────────
note "Phase 6 — pre-commit residual scan"
ALLOW_EMPTY=0
if [[ $DRY_RUN -eq 0 ]]; then
    HITS=$(grep -RIE 'ProjectHephaestus|project-hephaestus' . 2>/dev/null \
        | grep -v '\.git/' | grep -v '^Binary' || printf '')
    [[ -z "$HITS" ]] || { KEEP_WORKDIR=1; die "FAIL: residual old-name refs (first 10):
$(echo "$HITS" | head -10)"; }
    ok "  0 residual ProjectHephaestus|project-hephaestus refs"

    REMAIN=$(find . -maxdepth 1 -type d \( -name .claude-plugin -o -name .codex-plugin -o -name plugins -o -name skills -o -name assets -o -name '.agents' \) 2>/dev/null || printf '')
    [[ -z "$REMAIN" ]] || { KEEP_WORKDIR=1; die "FAIL: carve-out paths still present: $REMAIN"; }
    ok "  0 carve-out paths remain"

    DIFFSTAT=$(git diff --shortstat || printf '')
    if [[ -z "$DIFFSTAT" ]]; then
        note "  Empty diff -- will pass --allow-empty to commit"
        ALLOW_EMPTY=1
    else
        ok "  Diff: $DIFFSTAT"
    fi
fi

# ─── Phase 7: commit + push + PR ────────────────────────────────
note "Phase 7 — commit + push + open PR"
COMMIT_MSG="chore(hephaestus): drop agent-host plugin/skill surface (→ Athena) (@ADR-016)

Carve-out (removed):
  .claude-plugin/  .codex-plugin/  .agents/  plugins/  skills/  assets/

Stays in Hephaestus:
  hephaestus/ Python library (incl. hephaestus.automation, hephaestus.agents)
  tests/  scripts/  docs/  pyproject.toml  pixi.toml

Dep direction: Athena depends on Hephaestus. The [automation] extra
keeps installing 'hephaestus[automation]' from the Hephaestus repo.
hephaestus.automation stays in Hephaestus as a library subpackage per
ADR-016 + runbook §3a."

if [[ $DRY_RUN -eq 0 ]]; then
    commit_args=( -m "$COMMIT_MSG" )
    [[ $ALLOW_EMPTY -eq 1 ]] && commit_args+=( --allow-empty )

    git add -A
    if ! git commit "${commit_args[@]}" 2>&1 | tail -5; then
        KEEP_WORKDIR=1
        die "git commit failed -- workdir preserved at $WORK/$NEW_REPO"
    fi

    read -r -p "  Push branch '$BRANCH' and open PR on $ORG/$NEW_REPO? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] \
        || { KEEP_WORKDIR=1; die "aborted before push -- workdir preserved at $WORK/$NEW_REPO"; }

    if ! git push -u origin "$BRANCH" 2>&1 | tail -10; then
        KEEP_WORKDIR=1
        die "git push failed -- workdir preserved at $WORK/$NEW_REPO"
    fi

    if [[ $NO_PR -eq 0 ]]; then
        PR_BODY="$(cat <<PRBODY
## Summary

Carves the agent-host plugin/skill tree of \`Hephaestus\` into a new
sibling repo \`Athena\`. Library surface untouched. Carve-out list per
[ADR-016](https://github.com/${ORG}/Odysseus/blob/main/docs/adr/016-split-hephaestus.md) +
[runbook §3a](https://github.com/${ORG}/Odysseus/blob/main/docs/runbooks/rename-and-split.md).

## What changed

\`\`\`
$(git diff --shortstat HEAD~1 HEAD 2>/dev/null || echo "(initial)")
\`\`\`

## Audit

- [x] Zero residual \`ProjectHephaestus|project-hephaestus\` refs
- [x] Zero carve-out paths remain on the branch
- [x] \`pyproject.toml\` distribution renamed to \`hephaestus\`
PRBODY
)"
        gh pr create --base "$DEFAULT_BRANCH" \
            --title "$PR_TITLE" \
            --body "$PR_BODY" \
            || die "gh pr create failed -- branch still up; open manually"
        ok "PR opened on $ORG/$NEW_REPO"
    else
        note "--no-pr set; PR not opened"
    fi

    ok "Done. Branch $BRANCH pushed; Hephaestus PR is now awaiting human review/merge per ADR-016."
else
    note "(dry-run) Plan preview complete. Re-run without --dry-run to execute."
fi
