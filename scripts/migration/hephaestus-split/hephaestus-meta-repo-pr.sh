#!/usr/bin/env bash
#
# hephaestus-meta-repo-pr.sh — Phase D of the ProjectHephaestus split
# --------------------------------------------------------------------
#
# Operates on the **Odysseus meta-repo** at the current working directory.
# Updates .gitmodules, justfile, .claude/settings.json, README ecosystem
# board, and any other touched files; opens a single consolidated PR
# titled accordingly.
#
# Per Odysseus/AGENTS.md, *submodule pin bumps* are cross-repo integration
# events. The resulting PR must NOT auto-merge. This script explicitly
# does NOT pass `--auto --rebase` to gh pr create.
#
# Requires:
#   - Phase A done (HomericIntelligence/Hephaestus renamed)
#   - Phase B PR merged into Hephaestus main
#   - Phase C done (HomericIntelligence/Athena created + populated)
#   - Odysseus working tree is clean (the script refuses otherwise)
#
# Touch surface (from docs/runbooks/rename-and-split.md §4):
#   .gitmodules                              ← rename Hephaestus, add Athena
#   shared/ProjectHephaestus → shared/Hephaestus   git mv
#   justfile                                 ← sed sweep + Athena recipes
#   .claude/settings.json                    ← jq rewrite + new Athena entry
#   docker-compose.e2e.yml                   ← paths (only if refs exist)
#   docs/architecture.md                     ← component inventory + diagram
#   CLAUDE.md                                ← repo structure block
#   README.md                                ← auto-regen ecosystem board
#   .github/PULL_REQUEST_TEMPLATE/*.md       ← if any refs

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────
ORG="HomericIntelligence"
OLD_PATH="shared/ProjectHephaestus"
NEW_PATH="shared/Hephaestus"
ATHENA_PATH="agentic/Athena"
ATHENA_URL="https://github.com/${ORG}/Athena.git"
BRANCH="chore/split-hephaestus-athena"
PR_TITLE="chore: drop 'Project' prefix and split Hephaestus → Hephaestus + Athena (@ADR-015 + @ADR-016)"

DRY_RUN=0
NO_PR=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [flags]

Phase D of the ProjectHephaestus → Hephaestus + Athena split. Operates
on the Odysseus meta-repo at the CURRENT working directory.

Flags:
    --dry-run        Print every command that would run; do not write.
    --no-pr          Commit + push only; skip gh pr create.
    --branch NAME    Override the feature branch (default: $BRANCH).
    --help           Show this help.
USAGE
}

# Silenced EXIT trap on die (so the trailing "Meta-repo is dirty on exit"
# reminder doesn't double up with the error), but we still surface a
# one-line git-status hint to the operator -- useful when partial edits
# from Phases 4-8 are sitting in the working tree on a guarded abort.
die() {
    printf '  ERROR  %s\n' "$*" >&2
    trap - EXIT
    if [[ -d .git ]] && [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
        printf '  NOTE   working tree is dirty after this abort -- inspect with: git status --short\n' >&2
    fi
    exit 1
}
note() { printf '  ----   %s\n' "$*"; }
ok()   { printf '  OK     %s\n' "$*"; }

# ─── Argument parsing ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=1; shift ;;
        --no-pr)         NO_PR=1; shift ;;
        --branch)        BRANCH="${2:-}"; shift 2 || die "--branch requires a name" ;;
        --help|-h)       usage; exit 0 ;;
        *)               die "Unknown argument: $1 (try --help)" ;;
    esac
done

[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--branch '$BRANCH' has illegal characters"

# ─── Preflight: must be inside a meta-repo like Odysseus ──────────
[[ -d .git     ]] || die "Not inside a git working tree"
[[ -f .gitmodules ]] || die ".gitmodules not found -- this script expects the Odysseus meta-repo (or similar)"
[[ "$(basename "$(git rev-parse --show-toplevel)" 2>/dev/null)" == "Odysseus" ]] \
    || note "working tree is not named Odysseus -- continuing because .gitmodules is present"
note "Working tree OK: $(git rev-parse --show-toplevel)"

# Phase A/B/C state check
note "Preflight: phases A, B, C"
gh --version >/dev/null || die "gh CLI not installed"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh not authenticated -- run 'gh auth login' first"
gh repo view "$ORG/Hephaestus" --json name >/dev/null 2>&1 \
    || die "$ORG/Hephaestus not on GitHub -- Phase A incomplete"
gh repo view "$ORG/Athena"    --json name >/dev/null 2>&1 \
    || die "$ORG/Athena not on GitHub -- Phase C incomplete"
ok "Hephaestus + Athena both present on GitHub"

# Working-tree must be clean — but only when actually executing.  A
# preview-only --dry-run must work on any working tree state, otherwise
# an operator cannot sanity-check the script's plan against a tree that
# still carries partial edits from earlier aborts.
if [[ ${DRY_RUN:-0} -eq 0 ]] && [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    die "Working tree is dirty -- commit/stash before running this script:
$(git status --short | head -10)"
fi
if [[ ${DRY_RUN:-0} -eq 0 ]]; then
    ok "Working tree clean"
else
    CT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    note "(dry-run: $CT modified file(s) in working tree -- preview only, no commit/push)"
fi

# Cleanup-aware trap: if we exit with a dirty working tree, leave the
# operator a reminder. (Unlike the other two scripts, Phase D operates
# in the meta-repo's own working tree, not a /tmp checkout.)
trap '[[ -n "$(git status --porcelain 2>/dev/null || true)" ]] && \
    note "Meta-repo is dirty on exit -- review with: git diff, then git add -p / git reset as needed"' EXIT

# Branch creation
DEFAULT_BRANCH=$(gh repo view "$ORG/Odysseus" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
[[ -n $DEFAULT_BRANCH ]] || DEFAULT_BRANCH=main

if [[ $DRY_RUN -eq 0 ]]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
        note "Branch $BRANCH exists locally -- using it"
        git checkout "$BRANCH"
    else
        note "Creating branch $BRANCH off $DEFAULT_BRANCH"
        git checkout -b "$BRANCH"
    fi
fi

# ─── Phase 4: .gitmodules ────────────────────────────────────────
note "Phase 4 — .gitmodules: rename Hephaestus + add Athena"

if [[ $DRY_RUN -eq 0 ]]; then
    # 4a. Rename submodule: shared/ProjectHephaestus → shared/Hephaestus
    if grep -q '\["shared/ProjectHephaestus"\]' .gitmodules; then
        note "  Renaming submodule $OLD_PATH → $NEW_PATH"
        # Rewrite the section header AND its path= and url= lines
        sed -i -E \
            -e "s|^\[submodule \"shared/ProjectHephaestus\"\]|\[submodule \"shared/Hephaestus\"\]|" \
            -e "s|^(\s*)path = shared/ProjectHephaestus$|\1path = shared/Hephaestus|" \
            -e "s|^(\s*)url = https://github.com/HomericIntelligence/ProjectHephaestus\\.git$|\1url = https://github.com/HomericIntelligence/Hephaestus.git|" \
            .gitmodules
        ok "  .gitmodules entry renamed"
    else
        note "  (No $OLD_PATH entry in .gitmodules -- possibly already renamed)"
    fi

    # 4b. Add Athena submodule
    if grep -q '\["agentic/Athena"\]' .gitmodules || [[ -d "$ATHENA_PATH" ]]; then
        note "  (Athena already present -- skipping submodule add)"
    else
        note "  Adding submodule $ATHENA_PATH"
        git submodule add "$ATHENA_URL" "$ATHENA_PATH" 2>&1 | tail -5
    fi

    # 4c. Move local checkout directory
    if [[ -d "$OLD_PATH" ]]; then
        note "  git mv $OLD_PATH → $NEW_PATH"
        git mv "$OLD_PATH" "$NEW_PATH"
    elif [[ -d "$NEW_PATH" ]]; then
        note "  (local checkout already at $NEW_PATH)"
    fi

    # 4d. Refresh submodule internal bookkeeping
    git submodule sync --recursive >/dev/null 2>&1 \
        || die "git submodule sync failed -- inspect .git/config vs .gitmodules; abort before commit"
else
    note "(dry-run) would: rename submodule entry in .gitmodules, git submodule add $ATHENA_URL, git mv $OLD_PATH $NEW_PATH"
fi

# ─── Phase 5: justfile ──────────────────────────────────────────
note "Phase 5 — justfile: sed sweep + Athena recipes"

if [[ $DRY_RUN -eq 0 ]]; then
    [[ -f justfile ]] || die "justfile not found at repo root"

    # 5a. Path sed
    sed -i 's|shared/ProjectHephaestus|shared/Hephaestus|g' justfile
    note "  Path rewrite done (shared/ProjectHephaestus → shared/Hephaestus)"

    # 5b. Comment header updates if present
    sed -i \
        -e 's|Shared Utilities (ProjectHephaestus)|Shared Utilities (Hephaestus)|g' \
        -e 's|Skills Marketplace (ProjectMnemosyne)|Skills Marketplace (Mnemosyne)|g' \
        justfile

    # 5c. Athena lifecycle recipes — append if not already present
    if ! grep -q '^athena-start:' justfile; then
        cat >> justfile <<'JUSTEOF'

# ─── Athena (agent-host plugins/skills surface) ────────────────
# Carved out of Hephaestus per ADR-016. Library half stays in
# shared/Hephaestus; plugin/skill half lives here.

athena-start:
    cd agentic/Athena && just start

athena-lint:
    cd agentic/Athena && just lint

athena-test:
    cd agentic/Athena && just test

athena-bootstrap:
    @echo "Athena plugin manifest: agentic/Athena/.claude-plugin/plugin.json"
    @echo "Enable in Claude Code: 'athena@Athena: true' in ~/.claude/settings.json"
JUSTEOF
        ok "  athena-* recipes appended"
    else
        note "  (Athena recipes already present -- skipping append)"
    fi
else
    note "(dry-run) would: sed-sweep justfile + append athena-* recipes"
fi

# ─── Phase 6: .claude/settings.json ──────────────────────────────
note "Phase 6 — .claude/settings.json: rename plugin entry + add Athena"

if [[ $DRY_RUN -eq 0 ]]; then
    [[ -f .claude/settings.json ]] || note "  (no .claude/settings.json present -- skip)"

    if [[ -f .claude/settings.json ]] && command -v jq >/dev/null 2>&1; then
        jq '
            # Rename "hephaestus@ProjectHephaestus" → "hephaestus@Hephaestus"
            if (.enabledPlugins // {}) | has("hephaestus@ProjectHephaestus") then
                .enabledPlugins = (.enabledPlugins | to_entries
                    | map(if .key == "hephaestus@ProjectHephaestus"
                          then .key = "hephaestus@Hephaestus"
                          else . end)
                    | from_entries)
            else . end
            # Add "athena@Athena": true if absent
            | if (.enabledPlugins // {}) | has("athena@Athena")
              then .
              else .enabledPlugins = ((.enabledPlugins // {}) + { "athena@Athena": true })
              end
        ' .claude/settings.json > .claude/settings.json.new && mv .claude/settings.json.new .claude/settings.json
        ok "  settings.json updated"
    elif [[ -f .claude/settings.json ]]; then
        note "  WARNING: jq not installed -- skipping .claude/settings.json rewrite (do manually)"
    fi
fi

# ─── Phase 7: docker-compose.e2e.yml + docs/architecture.md + CLAUDE.md
note "Phase 7 — sweep project-prefixed refs in compose + docs"

if [[ $DRY_RUN -eq 0 ]]; then
    # docker-compose.e2e.yml — only touch if it has Hephaestus refs
    if [[ -f docker-compose.e2e.yml ]] && grep -qE 'ProjectHephaestus' docker-compose.e2e.yml; then
        sed -i 's|ProjectHephaestus|Hephaestus|g' docker-compose.e2e.yml
        ok "  docker-compose.e2e.yml updated"
    fi

    # docs/architecture.md
    if [[ -f docs/architecture.md ]]; then
        sed -i \
            -e 's|ProjectHephaestus|Hephaestus|g' \
            -e 's|ProjectMnemosyne|Mnemosyne|g' \
            -e 's|ProjectArgus|Argus|g' \
            docs/architecture.md
        ok "  docs/architecture.md updated"
    fi

    # CLAUDE.md — repo structure block + key-principle #2
    if [[ -f CLAUDE.md ]]; then
        sed -i \
            -e 's|control/ProjectAgamemnon|control/Agamemnon|g' \
            -e 's|control/ProjectNestor|control/Nestor|g' \
            -e 's|shared/ProjectHephaestus|shared/Hephaestus|g' \
            -e 's|ProjectAgamemnon (control/ProjectAgamemnon)|Agamemnon (control/Agamemnon)|g' \
            -e 's|ProjectHermes|Hermes|g' \
            -e 's|ProjectMnemosyne|Mnemosyne|g' \
            CLAUDE.md
        ok "  CLAUDE.md updated"
    fi

    # PR template — only touch the dashboard link if it still points at ProjectArgus
    if [[ -d .github/PULL_REQUEST_TEMPLATE ]] && grep -rlq 'ProjectArgus' .github/PULL_REQUEST_TEMPLATE 2>/dev/null; then
        find .github/PULL_REQUEST_TEMPLATE -type f -exec sed -i 's|ProjectArgus|Argus|g' {} +
        ok "  .github/PULL_REQUEST_TEMPLATE/* updated"
    fi

    # Meta-repo-owned install + e2e scripts (per ADR-015/016 — meta-repo
    # owns top-level install runners; renaming inside each submodule is
    # the submodule's own PR concern, NOT ours).
    for f in install.sh install_dev.sh e2e/claude-myrmidon-multi.py; do
        if [[ -f "$f" ]] && grep -qE 'ProjectHephaestus|project-hephaestus' "$f"; then
            sed -i -e 's|ProjectHephaestus|Hephaestus|g' \
                   -e 's|project-hephaestus|hephaestus|g' "$f"
            ok "  $f updated"
        fi
    done
    if [[ -d scripts/install ]] && grep -RlE 'ProjectHephaestus|project-hephaestus' scripts/install/ >/dev/null 2>&1; then
        find scripts/install -type f -exec sed -i -e 's|ProjectHephaestus|Hephaestus|g' \
                                              -e 's|project-hephaestus|hephaestus|g' {} +
        ok "  scripts/install/* updated"
    fi
    # Other e2e shell harnesses (validate-conan-install.sh, validate-pip-install.sh, etc.)
    for f in e2e/*.sh; do
        [[ -f "$f" ]] || continue
        if grep -qE 'ProjectHephaestus|project-hephaestus' "$f"; then
            sed -i -e 's|ProjectHephaestus|Hephaestus|g' \
                   -e 's|project-hephaestus|hephaestus|g' "$f"
            ok "  $(basename "$f") updated"
        fi
    done
fi

# ─── Phase 8: README ecosystem board auto-regen ─────────────────
note "Phase 8 — README ecosystem CI table auto-regen (if just ecosystem-table exists)"

if [[ $DRY_RUN -eq 0 ]]; then
    if grep -q '^ecosystem-table:' justfile 2>/dev/null; then
        note "  Running 'just ecosystem-table'..."
        if just ecosystem-table 2>&1 | tail -10; then
            ok "  README ecosystem table regenerated"
        else
            note "  WARNING: just ecosystem-table failed -- check manually before merging"
        fi
    else
        note "  (no 'ecosystem-table:' recipe in justfile -- manual regen required)"
    fi
fi

# ─── Phase 9: pre-commit guard + commit + push + PR ─────────────
note "Phase 9 — pre-commit guard + commit + push + open PR (HUMAN MERGE per AGENTS.md)"

if [[ $DRY_RUN -eq 0 ]]; then
    # Exclude:
    #   docs/        — ADR-015, ADR-016, docs/runbooks/rename-and-split.md
    #                  legitimately keep "ProjectHephaestus" for historical
    #                  reasons (the ADRs *describe* the rename).
    #   agentic/, shared/, ci-cd/, control/, provisioning/, infrastructure/,
    #     research/, testing/   — submodules; each is its own repo per
    #                  AGENTS.md ("Changes belong in each submodule's own
    #                  repo and PR process"). The meta-repo PR has zero
    #                  authority to rewrite content inside a submodule.
    #   backups/     — configs/github/backups/ is a verbatim GitHub-API
    #                  snapshot from a prior migration. Renaming inside it
    #                  would destroy historical fidelity for no win.
    #   tools/, hephaestus-split/ — long-lived wrappers (rename-repo.sh,
    #                  snapshot-protection.sh) and the migration scripts
    #                  themselves intentionally reference the old name on
    #                  purpose; they ARE the rename gas pedal.
    #   CHANGELOG.md — version-history ledger. Entries like
    #                  "v0.4.0: enabled hephaestus@ProjectHephaestus"
    #                  are historical record; rewriting them would
    #                  falsify what actually shipped.
    HITS=$(grep -RnE 'ProjectHephaestus|project-hephaestus' . \
        --exclude-dir=.git --exclude-dir=.pixi --exclude-dir=node_modules \
        --exclude-dir=agentic --exclude-dir=shared --exclude-dir=docs \
        --exclude-dir=ci-cd --exclude-dir=control --exclude-dir=provisioning \
        --exclude-dir=infrastructure --exclude-dir=research --exclude-dir=testing \
        --exclude-dir=backups --exclude-dir=tools --exclude-dir=hephaestus-split \
        --exclude=CHANGELOG.md \
        2>/dev/null || true)
    [[ -z "$HITS" ]] || die "FAIL: residual ProjectHephaestus refs in meta-repo (first 10):
$(echo "$HITS" | head -10)"
    ok "  0 residual ProjectHephaestus refs in meta-repo"

    DIFFSTAT=$(git diff --shortstat HEAD || true)
    if [[ -z "$DIFFSTAT" ]]; then
        die "Empty diff -- the script's pre-commit guard caught a no-op (check that the prior phases actually changed anything)"
    fi
    note "  Diff: $DIFFSTAT"

    COMMIT_MSG="chore: drop 'Project' prefix and split Hephaestus → Hephaestus + Athena

@ADR-015 + @ADR-016. Submodule pin bump event — held for human merge
per Odysseus/AGENTS.md (cross-repo integration).

.gitmodules: shared/ProjectHephaestus → shared/Hephaestus;
             added agentic/Athena → HomericIntelligence/Athena

justfile: path rewrites; added athena-start/lint/test/bootstrap recipes
.claude/settings.json: hephaestus@ProjectHephaestus → hephaestus@Hephaestus;
                       added athena@Athena: true
docker-compose.e2e.yml / docs/architecture.md / CLAUDE.md / PR templates:
                       project-prefix sed sweep
README.md: ecosystem CI board regenerated
"

    git add -A
    if ! git commit -m "$COMMIT_MSG" 2>&1 | tail -5; then
        die "git commit failed"
    fi

    read -r -p "  Push branch '$BRANCH' and open PR on Odysseus? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] \
        || die "aborted before push -- branch $BRANCH is local-only"

    if ! git push -u origin "$BRANCH" 2>&1 | tail -10; then
        die "git push failed -- inspect locally"
    fi

    if [[ $NO_PR -eq 0 ]]; then
        PR_BODY="$(cat <<PRBODY
## Summary

Phase D of the ProjectHephaestus → Hephaestus + Athena split. Multi-repo
integration PR — held for human merge per \`Odysseus/AGENTS.md\`
(submodule pin bumps are cross-repo integration events).

Closes the tracking issue for ADR-015 + ADR-016.

## Touch surface

\`\`\`
$(git diff --shortstat HEAD~1 HEAD 2>/dev/null || echo "(initial)")
\`\`\`

## Verify before merge

- [x] 0 residual \`ProjectHephaestus|project-hephaestus\` refs in meta-repo
- [x] \`.gitmodules\` lists \`shared/Hephaestus\` (renamed) AND \`agentic/Athena\` (new)
- [x] Hephaestus PR (Phase B) **merged**
- [x] Athena main (Phase C) **populated**
- [x] CI green on Hephaestus + Athena + Odysseus default branches

## Pre-merge acceptance

\`\`\`bash
# Verify each submodule loads on the Pin URL
git submodule update --init --recursive
just ci
just ecosystem-table && git diff --quiet README.md    # regenerated board
\`\`\`
PRBODY
)"
        # Per AGENTS.md: NO --auto --rebase. Submodule pin bumps are
        # cross-repo integration events that need human merge.
        gh pr create --base "$DEFAULT_BRANCH" \
            --title "$PR_TITLE" \
            --body "$PR_BODY" \
            || die "gh pr create failed -- branch is up; open manually"
        ok "PR opened on Odysseus (NOT auto-merge enabled)"

        note "Reminder: do NOT enable --auto --rebase on this PR."
        note "Reminder: this is a cross-repo integration event — only"
        note "         @mvillmow (or on-call operator) should merge."
    fi

    ok "Done. Phase D PR is open and ready for human review."
else
    note "(dry-run) Plan preview complete. Re-run without --dry-run to execute."
fi
