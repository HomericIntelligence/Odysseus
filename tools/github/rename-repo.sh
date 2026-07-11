#!/usr/bin/env bash
# =============================================================================
# tools/github/rename-repo.sh — HomericIntelligence repo-rename driver
# =============================================================================
# Renames a HomericIntelligence repo on GitHub and opens a follow-up PR that
# rewrites the project's self-name inside the repo (README, CLAUDE.md, AGENTS.md,
# pixi.toml, CHANGELOG.md, etc.).
#
# Pipeline (Phases 1–6)
#   1. gh repo rename                          (destructive — URL flips immediately)
#   2. clone the renamed repo                  (throw-away workdir)
#   3. sed-based internal ref rename           (CamelCase + kebab-case + SHOUTY)
#   4. pre-commit residual-hit guard           (refuses to commit if dirty)
#   5. push branch + gh pr create              (auto-generated PR body)
#   6. post-rename housekeeping checklist      (printed; NOT automated)
#
# Defaults to ProjectArgus -> Argus. Override --old / --new for the rest of
# the ecosystem. Pass --dry-run to see the plan without executing destructive
# steps. Pass --pr-only if Phase 1 was already done. Pass --no-pr to rename
# and commit but skip the PR.
#
# Usage
#   tools/github/rename-repo.sh                                       # default pair
#   tools/github/rename-repo.sh --dry-run                             # show plan only
#   tools/github/rename-repo.sh --no-pr                               # rename + commit only
#   tools/github/rename-repo.sh --pr-only                             # skip rename, only PR
#   tools/github/rename-repo.sh --old ProjectHermes --new Hermes
#   tools/github/rename-repo.sh --org HomericIntelligence --old X --new Y --branch feat/x
#
# Required tools: gh v2.30+ (tested on v2.96.0), git, sed, grep, find, xargs,
#                 mktemp, realpath. Authenticated to GitHub with admin on
#                 the source repo.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
ORG="HomericIntelligence"
OLD_REPO="ProjectArgus"
NEW_REPO="Argus"
BRANCH="chore/rename-drop-project-prefix"

DRY_RUN=0
PR_ONLY=0
SKIP_PR=0

# -----------------------------------------------------------------------------
# Pretty output
# -----------------------------------------------------------------------------
die()  { printf '\e[31m✗ %s\e[0m\n' "$*" >&2; exit 1; }
note() { printf '\e[36m→ %s\e[0m\n' "$*"; }
ok()   { printf '\e[32m✓ %s\e[0m\n' "$*"; }
warn() { printf '\e[33m! %s\e[0m\n' "$*" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || die "missing required command: $1 (try installing or check PATH)"
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    sed -n '3,33p' "$0"
    cat <<USAGE

Options
  --old NAME        Old repo name (default: ProjectArgus)
  --new NAME        New repo name (default: Argus)
  --org NAME        GitHub org (default: HomericIntelligence)
  --branch NAME     PR branch name (default: chore/rename-drop-project-prefix)
  --dry-run         Show the plan; do not execute destructive steps
  --pr-only         Skip Phase 1 (rename assumed already done)
  --no-pr           Skip Phase 5 (do not open a PR on the new repo)
  -h, --help        Show this help

Examples
  tools/github/rename-repo.sh
  tools/github/rename-repo.sh --old ProjectHermes --new Hermes
  tools/github/rename-repo.sh --dry-run --org HomericIntelligence --old ProjectOdyssey --new Odyssey
USAGE
    exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --old)     OLD_REPO="$2"; shift 2 ;;
        --new)     NEW_REPO="$2"; shift 2 ;;
        --org)     ORG="$2"; shift 2 ;;
        --branch)  BRANCH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --pr-only) PR_ONLY=1; shift ;;
        --no-pr)   SKIP_PR=1; shift ;;
        -h|--help) usage 0 ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
done

# lowercase + kebab-case variants of OLD and NEW for the second-pass sed
LOWER_OLD="$(printf '%s' "$OLD_REPO"  | tr '[:upper:]' '[:lower:]')"
LOWER_NEW="$(printf '%s' "$NEW_REPO"  | tr '[:upper:]' '[:lower:]')"
KEBAB_OLD="$(printf '%s' "$LOWER_OLD" | tr _ -)"
KEBAB_NEW="$LOWER_NEW"
SHOUTY_OLD="$(printf '%s' "$OLD_REPO" | tr '[:lower:]' '[:upper:]' | tr _ -)"
SHOUTY_NEW="$(printf '%s' "$NEW_REPO" | tr '[:lower:]' '[:upper:]')"

# Input validation: refuse characters that confuse sed delimiters or break
# git refnames. Allowed sets intentionally exclude the chars git itself
# rejects: ':'  '?'  '*'  '['  '~'  '^'  ' '  '\t'.
name_re='^[A-Za-z0-9._-]+$'
branch_re='^[A-Za-z0-9._/-]+$'
[[ "$OLD_REPO" =~ $name_re   ]] || die "--old must match A-Za-z0-9._-  (got: $OLD_REPO)"
[[ "$NEW_REPO" =~ $name_re   ]] || die "--new must match A-Za-z0-9._-  (got: $NEW_REPO)"
[[ "$BRANCH"  =~ $branch_re ]] || die "--branch must match A-Za-z0-9._/- (got: $BRANCH)"

# ProjectHephaestus is being split into Hephaestus (library) + Athena
# (plugins/skills), not renamed. This script will not handle that.
[[ "$OLD_REPO" == "ProjectHephaestus" ]] && die \
    "--old ProjectHephaestus requires the split procedure; see docs/runbooks/rename-and-split.md"

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_cmd gh
require_cmd git
require_cmd sed
require_cmd grep
require_cmd find
require_cmd xargs
require_cmd mktemp
require_cmd realpath

# Verify gh auth and capture login
GH_LOGIN="$(gh api user --jq .login 2>/dev/null || printf '')"
[[ -n "$GH_LOGIN" ]] || die "gh CLI is not authenticated. Run 'gh auth login' first."

note "Preflight"
echo "  gh version:        $(gh --version | head -1)"
echo "  authenticated as:  $GH_LOGIN"
echo "  target org:        $ORG"
echo "  old repo:          $OLD_REPO"
echo "  new repo:          $NEW_REPO"
echo "  branch:            $BRANCH"
echo "  --dry-run:         $DRY_RUN"
echo "  --pr-only:         $PR_ONLY"
echo "  --no-pr:           $SKIP_PR"
echo

[[ $OLD_REPO == "$NEW_REPO" ]] && die "--old and --new are identical; nothing to rename."

# Confirm the source repo exists
if [[ $PR_ONLY -eq 0 ]]; then
    if ! gh repo view "$ORG/$OLD_REPO" --json name >/dev/null 2>&1; then
        die "source repo not visible: $ORG/$OLD_REPO"
    fi
fi

# Confirm the new repo does NOT already exist (or it would block rename)
if ! [[ $PR_ONLY -eq 1 || $DRY_RUN -eq 1 ]]; then
    if gh repo view "$ORG/$NEW_REPO" --json name >/dev/null 2>&1; then
        die "destination repo already exists: $ORG/$NEW_REPO (use --pr-only if rename was already done)"
    fi
fi

# -----------------------------------------------------------------------------
# Phase 1: gh repo rename
# -----------------------------------------------------------------------------
if [[ $PR_ONLY -eq 0 ]]; then
    note "Phase 1 — gh repo rename $ORG/$OLD_REPO → $ORG/$NEW_REPO"
    echo "  This is destructive: the repo URL flips immediately."
    echo "  Issues, PRs, releases, git history, and web traffic auto-redirect are preserved."
    echo

    if [[ $DRY_RUN -eq 0 ]]; then
        read -r -p "  Confirm rename of $ORG/$OLD_REPO to $ORG/$NEW_REPO? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || die "aborted at confirmation"

        gh repo rename "$NEW_REPO" \
            --repo "$ORG/$OLD_REPO" \
            --confirm

        actual="$(gh repo view "$ORG/$NEW_REPO" --json name --jq .name)"
        [[ "$actual" == "$NEW_REPO" ]] \
            || die "rename verification failed: got '$actual'"
        ok "renamed: $ORG/$OLD_REPO → $ORG/$NEW_REPO"
    else
        echo "  (dry-run) would run: gh repo rename \"$NEW_REPO\" --repo \"$ORG/$OLD_REPO\" --confirm"
    fi
fi

# -----------------------------------------------------------------------------
# Phase 2: clone renamed repo
# -----------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rename-XXXXXX")"
# Trap fires on every exit path (success, error, signal). It removes the
# throw-away workdir UNLESS the operator has flagged it for preservation
# (e.g. --no-pr leaves the branch dirty for manual review, or a die() path
# runs while the operator wants to inspect what went wrong).
KEEP_WORKDIR=0
trap '[[ "${KEEP_WORKDIR:-0}" -eq 0 ]] && rm -rf "$WORK"' EXIT

if [[ $PR_ONLY -eq 1 && ! -d "$WORK/checkout" ]]; then
    # --pr-only without fresh clone: we'll re-clone fresh on the new URL.
    :
fi

note "Phase 2 — clone $ORG/$NEW_REPO"
echo "  workdir (auto-cleaned unless --no-pr holds it open): $WORK"

if [[ $DRY_RUN -eq 1 ]]; then
    mkdir -p "$WORK/checkout"
    cd "$WORK/checkout"
    git init -q
    echo "  (dry-run) standing in synthetic empty repo; sed pipeline below "
    echo "  will be a no-op until you re-run without --dry-run."
else
    ( cd "$WORK" && gh repo clone "$ORG/$NEW_REPO" checkout )
    cd "$WORK/checkout"
    ok "cloned: $ORG/$NEW_REPO → $WORK/checkout"
fi

# -----------------------------------------------------------------------------
# Phase 3: sed-based internal ref rename
# -----------------------------------------------------------------------------
# Refuse to run if the worktree has stray uncommitted changes from a prior
# partial run; the sed pipeline would silently corrupt them.
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ -n "$(git status --porcelain 2>/dev/null || printf '')" ]]; then
        KEEP_WORKDIR=1
        die "worktree has uncommitted changes -- clean or stash first"
    fi
fi
note "Phase 3 — sed-based internal ref rename"
echo "  Pattern 1 (CamelCase):    $OLD_REPO     → $NEW_REPO"
echo "  Pattern 2 (kebab-case):   $KEBAB_OLD    → $KEBAB_NEW"
echo "  Pattern 3 (SHOUTY_SNAKE): $SHOUTY_OLD   → $SHOUTY_NEW"

# Three independent sed passes, each case-sensitive, run on a guarded find
# that excludes .git, common binary files, fonts, and lockfiles.
SED_ARGS=(
    -e "s/${OLD_REPO}/${NEW_REPO}/g"
    -e "s/${KEBAB_OLD}/${KEBAB_NEW}/g"
    -e "s/${SHOUTY_OLD}/${SHOUTY_NEW}/g"
)

find . -type f \
    ! -path './.git/*' \
    ! -name '*.png'  ! -name '*.jpg'  ! -name '*.gif' \
    ! -name '*.ico'  ! -name '*.webp' \
    ! -name '*.woff' ! -name '*.woff2' ! -name '*.ttf' \
    ! -name '*.lock' \
    -print0 | xargs -r -0 sed -i "${SED_ARGS[@]}"

# CHANGELOG walk-back: rewrite only the *forward-looking* compare/release
# URL footnotes at the bottom of the file. Historical entries in the body
# stay verbatim per ADR-014 (evidence integrity). Match the conventional
# filenames used across the ecosystem.
for cf in CHANGELOG.md CHANGELOG.rst HISTORY.md HISTORY.rst NEWS.md RELEASES.md; do
    if [[ -f "$cf" ]]; then
        sed -i \
            -e "s#https://github.com/${ORG}/${OLD_REPO}/compare#https://github.com/${ORG}/${NEW_REPO}/compare#g" \
            -e "s#https://github.com/${ORG}/${OLD_REPO}/releases#https://github.com/${ORG}/${NEW_REPO}/releases#g" \
            "$cf"
    fi
done

# -----------------------------------------------------------------------------
# Phase 4: pre-commit guard (zero residual hits)
# -----------------------------------------------------------------------------
note "Phase 4 — pre-commit guard: residual hit check"

if [[ $DRY_RUN -eq 1 ]]; then
    note "  dry-run: skipping residual check (workdir is synthetic)."
else
    # -I  skip binary files. Allow .git/ to leak (we exclude it above anyway).
    HITS="$(
        grep -RIE \
            --binary-files=without-match \
            -e "${OLD_REPO}" \
            -e "${KEBAB_OLD}" \
            -e "${SHOUTY_OLD}" \
            . 2>/dev/null \
        | grep -v '^\./\.git/' \
        || printf ''
    )"

    if [[ -n "$HITS" ]]; then
        warn "FAIL: residual old-name refs after sed:"
        printf '%s\n' "$HITS" | head -80 >&2
        KEEP_WORKDIR=1
        die "manual fixup required — workdir preserved at $WORK/checkout"
    fi
    ok "OK: zero residual $OLD_REPO|$KEBAB_OLD|$SHOUTY_OLD hits"
fi

# Diff summary (so PR body and human review see what changed)
if [[ $DRY_RUN -eq 0 ]]; then
    note "Phase 4.5 — diff summary"
    git status --short | head -50
    git diff --shortstat
    echo
fi

# -----------------------------------------------------------------------------
# Phase 5: commit + push + PR
# -----------------------------------------------------------------------------
if [[ $SKIP_PR -eq 1 ]]; then
    note "Phase 5 — SKIPPED (--no-pr). Branch left dirty for manual review."
    echo "  Workdir preserved at: $WORK/checkout"
    echo "  You can: cd $WORK/checkout && git checkout -b <branch> && git add -A && git commit && git push"
    KEEP_WORKDIR=1
    exit 0
fi

note "Phase 5 — commit + push + PR"

if [[ $DRY_RUN -eq 1 ]]; then
    note "  (dry-run) would commit on branch '$BRANCH' and open a PR against main"
    note "  (dry-run) would run: gh pr create --base main --repo \"$ORG/$NEW_REPO\""
    exit 0
fi

# Committer identity from gh user record
git config user.name  "$(gh api user --jq .login)"
git config user.email "$(gh api user --jq .email)"

# Branch off origin's default branch (or whatever the repo's primary ref is).
DEFAULT_BRANCH="$(gh repo view "$ORG/$NEW_REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
[[ -n "$DEFAULT_BRANCH" ]] || die \
    "could not determine default branch for $ORG/$NEW_REPO -- API response empty"

# Fetch + branch. If the local branch already exists from a prior partial
# run, checkout existing. Refuse to reset hard if local differs from
# origin (operator may have stashed or made commits that `reset --hard`
# would silently destroy).
git fetch origin "$DEFAULT_BRANCH" || die "git fetch origin $DEFAULT_BRANCH failed"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH" --quiet
    if ! git diff --quiet "refs/heads/$BRANCH" "origin/$DEFAULT_BRANCH" --; then
        KEEP_WORKDIR=1
        die "local branch '$BRANCH' diverges from origin/$DEFAULT_BRANCH -- resolve manually"
    fi
    git reset --hard "origin/$DEFAULT_BRANCH" --quiet
else
    git checkout -b "$BRANCH" "origin/$DEFAULT_BRANCH" --quiet
fi

# Detect no-changes state. After --pr-only rerun, the sed pipeline is
# idempotent (already-renamed files do not re-match) and produces zero
# diff. Without an explicit choice, `git commit` would fail with
# "nothing to commit" and trip set -e before pre-push fire.
ALLOW_EMPTY=0
if [[ -z "$(git status --porcelain)" ]]; then
    note "no diff produced -- sed pipeline was a no-op (rename PR may already be open)"
    read -r -p "  Force an empty marker commit and reopen the PR? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || {
        KEEP_WORKDIR=1
        die "no-op -- check $ORG/$NEW_REPO for an existing rename PR"
    }
    ALLOW_EMPTY=1
fi

# Pre-push confirmation. After this gate we touch a remote branch and open
# a PR; aborting here leaves the workdir intact so the user can inspect.
read -r -p "  Push branch '$BRANCH' and open PR on $ORG/$NEW_REPO? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] \
    || { KEEP_WORKDIR=1; die "aborted before push -- workdir preserved at $WORK/checkout"; }

git add -A

COMMIT_MSG="chore(rename): drop Project prefix → $NEW_REPO

- README.md, CONTRIBUTING.md, CLAUDE.md, AGENTS.md: project self-name in prose
- pixi.toml: name = \"$KEBAB_NEW\" (was \"$KEBAB_OLD\")
- CHANGELOG.md: comparison-URL footnotes rewritten; historical entries preserved verbatim
- CODEOWNERS, SECURITY.md: project name references
- .github/PULL_REQUEST_TEMPLATE/* (if present): review-charter link target
- dashboard/{Dockerfile,README.md,docs/...}: org.opencontainers LABEL + HTTP refs
- certs/gen-certs.sh: cert subject CN/O
- scripts/setup.sh: header comments

Container names (e.g. ${KEBAB_NEW}-exporter, ${KEBAB_NEW}-loki, ...)
unchanged where already lowercase -- they already matched the bare form
and were not caught by any of the sed patterns."

commit_args=( -m "$COMMIT_MSG" )
[[ $ALLOW_EMPTY -eq 1 ]] && commit_args+=( --allow-empty )

git commit "${commit_args[@]}" || {
    # Normal-path commit failure (e.g. pre-commit hook rejected changes).
    KEEP_WORKDIR=1
    die "git commit failed -- inspect workdir at $WORK/checkout"
}

git push -u origin "$BRANCH"

# PR body: auto-generated, references the diff
PR_DIFF_FILES="$(git diff --name-only "origin/$DEFAULT_BRANCH"..."$BRANCH" | head -60)"
PR_DIFF_SHORTSTAT="$(git diff --shortstat "origin/$DEFAULT_BRANCH"..."$BRANCH")"

PR_BODY="$(cat <<EOF
## Rename: $ORG/$OLD_REPO → $ORG/$NEW_REPO

This PR is the follow-up to the GitHub-side \`gh repo rename\` (URL flipped in
Phase 1; this PR finishes the rename *inside* the repo).

### Diff summary

\`\`\`
$PR_DIFF_SHORTSTAT
\`\`\`

### Files updated

\`\`\`
$PR_DIFF_FILES
\`\`\`

### What this PR does NOT change

- Container names (\`${KEBAB_NEW}-exporter\`, \`${KEBAB_NEW}-loki\`, ...) where already
  lowercase — preserved (they already matched the bare form).
- \`CHANGELOG.md\` historical entries — preserved verbatim per
  [ADR-014](../Odysseus/blob/main/docs/adr/014-runnable-evidence-for-metric-claims.md) (evidence integrity).
- Branch protection / rulesets / secrets / environments — apply manually on
  the renamed repo (see Phase 6).

### Verification

- \`grep -RIE '$OLD_REPO|$KEBAB_OLD|$SHOUTY_OLD' .\` returns **zero** hits
  (Phase 4 pre-commit guard).
- CI green (lint, integration tests, package, dashboard, exporter).

### Followups (separate PRs)

1. \`$ORG/Odyssey\` — meta-repo PR updating \`.gitmodules\`, \`justfile\`,
   \`docker-compose.e2e.yml\`, \`tools/github/*.sh\`, \`scripts/install/*\`,
   \`e2e/start-*.sh\`, \`docs/{architecture,onboarding,deployment,repo-conventions}.md\`,
   \`.github/PULL_REQUEST_TEMPLATE/atlas-*.md\`.
2. Apply the same \`gh repo rename + sed\` sequence to the next prefixed repo
   in the queue (tools/github/rename-repo.sh is parametrized).
3. \`$ORG/Hephaestus\` and \`$ORG/Athena\` (\`ProjectHephaestus\` carve-out) —
   not a straight rename; handle as a separate procedure.
EOF
)"

gh pr create \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH" \
    --title "chore(rename): drop Project prefix → $NEW_REPO" \
    --body "$PR_BODY" \
    --repo "$ORG/$NEW_REPO"

ok "PR opened on $ORG/$NEW_REPO"
gh pr list --repo "$ORG/$NEW_REPO" --state open \
    --json number,title,url \
    | jq -r '.[] | "  → #\(.number): \(.title)\n     \(.url)"'

# -----------------------------------------------------------------------------
# Phase 6: post-rename housekeeping checklist (printed; NOT automated)
# -----------------------------------------------------------------------------
cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
Phase 6 — manual housekeeping checklist
────────────────────────────────────────────────────────────────────────────
[ ] Re-apply branch protection / rulesets on the new repo
      gh CLI does NOT migrate them. Two scripts in this repo handle the
      HomericIntelligence-wide set:
        tools/github/snapshot-protection.sh
        tools/github/remove-classic-protection.sh
[ ] Re-paste secrets / environments / deploy keys / variables
      They live on the OLD repo; the new one starts blank.
[ ] Verify Renovate / Dependabot pickup the new repo
      The HomericIntelligence bots may need to be re-granted access.
[ ] Open the parallel Odysseus meta-repo PR that updates .gitmodules +
      justfile + cross-references (separate from this PR).
[ ] Append a line to your local rename log:
      echo "$(date -u +%FT%TZ)  HomericIntelligence/ProjectArgus -> HomericIntelligence/Argus"
EOF

ok "Done. Workdir cleaned up at $WORK (unless --no-pr held it)."
