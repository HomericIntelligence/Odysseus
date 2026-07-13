#!/usr/bin/env bash
#
# athena-create.sh — Phase C of the ProjectHephaestus split (ADR-016)
# ---------------------------------------------------------------------
#
# Creates a brand-new HomericIntelligence/Athena repo and populates it
# with the agent-host plugin/skill surface that Phase B
# (hephaestus-prune-pr.sh) just carved out of Hephaestus.
#
# Requires:
#   - Phase A complete (HomericIntelligence/Hephaestus renamed)
#   - Phase B PR merged onto Hephaestus main (carve-out paths absent
#     on the source HEAD)
#
# By default refuses to run if a `HomericIntelligence/Athena` repo already exists
# (one-shot operation). Pass `--recover` to populate / repair an existing
# Athena repo instead — used to recover from incomplete prior Phase C runs
# (e.g. when the original Phase C silently skipped the carve-out copy
# because it tried to read from the post-Phase-B HEAD where the carve-out
# paths were already absent; see CHANGELOG entry "fix: athena-create.sh
# pre-Phase-B sha sourcing"). The `--carve-source-sha` flag pins the
# pre-Phase-B SHA the script copies from; default: walk `git log` to find
# the parent of Phase B's deletion commit.
#
# What it writes:
#   - pyproject.toml (athena; depends on hephaestus + [automation] extra)
#   - README.md (install instructions for Claude Code / Codex / Pi)
#   - AGENTS.md (boundary contract: Athena → Hephaestus one-way)
#   - LICENSE placeholder (carrying a pointer at the carve-out source SHA)
#   - .gitignore (Python/venv/build artifacts)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────
ORG="HomericIntelligence"
SOURCE_REPO="Hephaestus"
NEW_REPO="Athena"
SOURCE_SHA=""        # optional explicit pin; default = source HEAD

CARVE_OUT=(.claude-plugin .codex-plugin .agents plugins skills assets)

DRY_RUN=0
KEEP_WORKDIR=0
RECOVER=0
VALIDATE_RECOVERY=0
# Override the pre-Phase-B SHA the script copies from.  Default: walk
# `git log --diff-filter=D` on the carve-out paths to find the parent
# of the most recent deletion commit (i.e. the parent of Phase B's
# merge commit on Hephaestus main).
CARVE_SOURCE_SHA=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [flags]

Phase C of the ProjectHephaestus → Hephaestus + Athena split. Run AFTER
Phase B (hephaestus-prune-pr.sh) PR is merged onto Hephaestus main.

Flags:
    --dry-run              Print every command that would run; do not write.
    --keep-workdir         Leave /tmp/athena-create-* on exit (for inspection).
    --source-sha SHA       Pin the POST-Phase-B source commit the preflight
                          verifies Phase B on (default: source HEAD).
    --carve-source-sha SHA Override the PRE-Phase-B source commit the script
                          copies the carve-out from. Default: walk git-log
                          to locate the parent of the most recent deletion
                          commit on the carve-out paths.
    --recover              Tolerate $ORG/$NEW_REPO existing; populate / repair
                          it instead of refusing.  Pushes a new commit on
                          top of Athena's current main rather than creating
                          a fresh repo.
    --validate-recovery    Standalone preflight for --recover.  Clones the
                          source, walks git-log to confirm the pre-Phase-B
                          SHA, checks it out detached, and verifies every
                          carve-out path is PRESENT at that SHA.  Exits 0
                          with a printable plan (does not commit, push, or
                          touch $ORG/$NEW_REPO).  Run this before a live
                          --recover to sanity-check the SHA resolution.
                          Mutually exclusive with --dry-run.
    --help                 Show this help.
USAGE
}

die()  { printf '  ERROR  %s\n' "$*" >&2; exit 1; }
note() { printf '  ----   %s\n' "$*"; }
ok()   { printf '  OK     %s\n' "$*"; }

# ─── Argument parsing ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)           DRY_RUN=1; shift ;;
        --keep-workdir)      KEEP_WORKDIR=1; shift ;;
        --source-sha)        SOURCE_SHA="${2:-}"; shift 2 || die "--source-sha requires a value" ;;
        --carve-source-sha)  CARVE_SOURCE_SHA="${2:-}"; shift 2 || die "--carve-source-sha requires a value" ;;
        --recover)           RECOVER=1; shift ;;
        --validate-recovery) VALIDATE_RECOVERY=1; shift ;;
        --help|-h)           usage; exit 0 ;;
        *)                   die "Unknown argument: $1 (try --help)" ;;
    esac
done

# SHA must be hex; cheap regex over [0-9a-f]{7,40}
# SHA must be hex; accept uppercase or lowercase (git short SHAs are case-insensitive)
[[ -z "$SOURCE_SHA" || "$SOURCE_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] \
    || die "--source-sha '$SOURCE_SHA' is not a hex commit identifier"
[[ -z "$CARVE_SOURCE_SHA" || "$CARVE_SOURCE_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] \
    || die "--carve-source-sha '$CARVE_SOURCE_SHA' is not a hex commit identifier"

trap '[ "${KEEP_WORKDIR:-0}" -eq 0 ] && rm -rf "${WORK:-}"' EXIT

# ─── Preflight ───────────────────────────────────────────────────
note "Preflight: gh CLI + auth"
gh --version >/dev/null                || die "gh CLI not installed"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh not authenticated -- run 'gh auth login' first"

note "Preflight: source + target repo states"
gh repo view "$ORG/$SOURCE_REPO" --json name >/dev/null 2>&1 \
    || die "$ORG/$SOURCE_REPO missing -- Phase A incomplete"

if gh repo view "$ORG/$NEW_REPO" --json name >/dev/null 2>&1; then
    # --validate-recovery is read-only against the target repo and
    # never touches it, so the existence check is moot in that mode.
    if [[ $VALIDATE_RECOVERY -eq 1 ]]; then
        note "(--validate-recovery) $ORG/$NEW_REPO exists; ignore (validator never touches the target)"
    elif [[ $RECOVER -eq 0 ]]; then
        die "$ORG/$NEW_REPO already exists. Either Phase C is already done or the repo was created manually. Refusing to overwrite. (Pass --recover to populate / repair an existing Athena.)"
    else
        note "(--recover) $ORG/$NEW_REPO exists; will push carve-out commit on top of its current main"
    fi
elif [[ $RECOVER -eq 1 && $VALIDATE_RECOVERY -eq 0 ]]; then
    # --recover REQUIRES the target to exist; fail loudly rather than
    # letting `gh repo clone` emit a cryptic 404 two phases later.
    die "$ORG/$NEW_REPO does not exist. --recover requires the target repo to be present; pass without --recover to create it from scratch."
fi
ok "Preflight OK"

# ─── Phase 0: --validate-recovery standalone validator ─────
# If invoked with --validate-recovery, do the source clone + Phase B
# absence check + Phase 3b walkover + verify-presence, print a green
# plan, and exit 0 -- without ever touching the target repo.  This
# gives the operator a way to sanity-check the pre-Phase-B SHA walkover
# BEFORE committing to a live --recover run.
if [[ $VALIDATE_RECOVERY -eq 1 ]]; then
    [[ $DRY_RUN -eq 0 ]] || die "--validate-recovery is incompatible with --dry-run"
    [[ $RECOVER -eq 0 ]] || die "--validate-recovery is incompatible with --recover (use --recover WITHOUT --validate-recovery for the actual run)"

    note "VALIDATE-RECOVERY: cloning $ORG/$SOURCE_REPO into /tmp"
    WORK="$(mktemp -d -t athena-validate.XXXXXX)"
    # Honour KEEP_WORKDIR on the validate path too -- forensic
    # inspection of the resolved SHA wants the workdir preserved.
    trap '[ "${KEEP_WORKDIR:-0}" -eq 0 ] && rm -rf "${WORK:-}"' EXIT

    gh repo clone "$ORG/$SOURCE_REPO" "$WORK/source" 2>&1 | tail -3
    cd "$WORK/source"
    HEAD_SHA=$(git rev-parse HEAD)
    if [[ -n "$SOURCE_SHA" && "$HEAD_SHA" != "$SOURCE_SHA" ]]; then
        die "Source HEAD $HEAD_SHA does not match --source-sha $SOURCE_SHA"
    fi
    ok "Source cloned at $HEAD_SHA"

    note "VALIDATE-RECOVERY: Phase B absence check on $HEAD_SHA"
    for path in "${CARVE_OUT[@]}"; do
        [[ -e "$path" ]] && die "Carve-out path '$path' present on $ORG/$SOURCE_REPO@$HEAD_SHA -- Phase B PR is not merged yet"
    done
    ok "Phase B verified: all carve-out paths absent on HEAD"

    note "VALIDATE-RECOVERY: locating pre-Phase-B SHA via git log walk"
    if [[ -n "$CARVE_SOURCE_SHA" ]]; then
        ok "Pre-Phase-B SHA pinned via --carve-source-sha: $CARVE_SOURCE_SHA"
    else
        DELETE_LOG=$(git log --all --diff-filter=D --format='%H %s' -- .claude-plugin .codex-plugin .agents plugins skills assets 2>/dev/null | head -20)
        if [[ -z "$DELETE_LOG" ]]; then
            die "No commit deletes any carve-out path -- Phase B is intact (no carve-out visible). Use --carve-source-sha instead."
        fi
        PRUNE_COMMIT=$(echo "$DELETE_LOG" | head -1 | awk '{print $1}')
        CARVE_SOURCE_SHA=$(git rev-parse "${PRUNE_COMMIT}^" 2>/dev/null)
        [[ -n "$CARVE_SOURCE_SHA" ]] || die "Could not resolve pre-Phase-B parent of ${PRUNE_COMMIT}"
        ok "Pre-Phase-B SHA resolved via git-log walk: $CARVE_SOURCE_SHA (deletion commit ${PRUNE_COMMIT:0:12})"
    fi

    note "VALIDATE-RECOVERY: detached checkout at $CARVE_SOURCE_SHA + verify paths present"
    git checkout --quiet "$CARVE_SOURCE_SHA" 2>&1 \
        || { git fetch --quiet origin "$CARVE_SOURCE_SHA" 2>/dev/null; git checkout --quiet "$CARVE_SOURCE_SHA" || die "Could not checkout $CARVE_SOURCE_SHA"; }
    for path in "${CARVE_OUT[@]}"; do
        [[ -e "$path" ]] || die "Carve-out path '$path' absent at pre-Phase-B SHA $CARVE_SOURCE_SHA -- Phase B may have been squash-merged or force-pushed"
    done
    ok "All carve-out paths present at pre-Phase-B SHA $CARVE_SOURCE_SHA"

    note "VALIDATE-RECOVERY: summary"
    note "  plan: --recover --carve-source-sha $CARVE_SOURCE_SHA"
    ok "VALIDATE-RECOVERY: pre-Phase-B SHA is well-formed. Re-run with --recover [--carve-source-sha <SHA>] to apply."
    exit 0
fi

# ─── Working directory ───────────────────────────────────────────
WORK="$(mktemp -d -t athena-create.XXXXXX)"
note "Workdir: $WORK"

if [[ $DRY_RUN -eq 0 ]]; then
    note "Cloning $ORG/$SOURCE_REPO (depth=1) into $WORK/source"
    gh repo clone "$ORG/$SOURCE_REPO" "$WORK/source" 2>&1 | tail -3

    cd "$WORK/source"
    HEAD_SHA=$(git rev-parse HEAD)
    [[ -n "$SOURCE_SHA" ]] || SOURCE_SHA="$HEAD_SHA"
    if [[ "$HEAD_SHA" != "$SOURCE_SHA" ]]; then
        KEEP_WORKDIR=1
        die "Source HEAD $HEAD_SHA does not match --source-sha $SOURCE_SHA"
    fi
    ok "Source pinned to $SOURCE_SHA"

    note "Preflight: Phase B prune check on $SOURCE_SHA"
    for path in "${CARVE_OUT[@]}"; do
        if [[ -e "$path" ]]; then
            KEEP_WORKDIR=1
            die "FAIL: carve-out path '$path' still present on $ORG/$SOURCE_REPO@$SOURCE_SHA -- Phase B PR is not merged yet"
        fi
    done
    ok "All carve-out paths absent on source HEAD"

    # ─── Phase 3b: locate the pre-Phase-B sha to COPY from ─────────
    # The preflight above only verified Phase B absence; the COPY
    # itself must source from the pre-Phase-B HEAD where the paths
    # were still present.  Two ways to resolve:
    #   (a) user pinned via --carve-source-sha
    #   (b) walk `git log --diff-filter=D` for the first deletion
    #       commit on the carve-out paths, take its parent.
    if [[ -z "$CARVE_SOURCE_SHA" ]]; then
        note "Locating pre-Phase-B source via 'git log --diff-filter=D' on the carve-out paths"
        DELETE_LOG=$(git log --all --diff-filter=D --format='%H %s' -- .claude-plugin .codex-plugin .agents plugins skills assets 2>/dev/null | head -20)
        if [[ -z "$DELETE_LOG" ]]; then
            KEEP_WORKDIR=1
            die "No commit deletes any carve-out path in $WORK/source's git history -- Phase B is intact (no carve-out visible). Run with --carve-source-sha instead."
        fi
        PRUNE_COMMIT=$(echo "$DELETE_LOG" | head -1 | awk '{print $1}')
        [[ -n "$PRUNE_COMMIT" ]] || die "Could not parse deletion-commit SHA from 'git log' output"
        CARVE_SOURCE_SHA=$(git rev-parse "${PRUNE_COMMIT}^" 2>/dev/null)
        [[ -n "$CARVE_SOURCE_SHA" ]] || die "Could not resolve pre-Phase-B parent of ${PRUNE_COMMIT} -- pre-Phase-B SHA may not exist; pass --carve-source-sha to override."
        ok "Pre-Phase-B SHA resolved via git-log walk: $CARVE_SOURCE_SHA (deletion commit ${PRUNE_COMMIT:0:12})"
    else
        ok "Pre-Phase-B SHA pinned via --carve-source-sha: $CARVE_SOURCE_SHA"
    fi

    note "Checking out pre-Phase-B SHA $CARVE_SOURCE_SHA (detached; carve-out paths are present there)"
    if ! git checkout --quiet "$CARVE_SOURCE_SHA" 2>&1; then
        note "  SHA not in default clone — deepening fetch"
        git fetch --quiet --unshallow origin "$CARVE_SOURCE_SHA" 2>/dev/null \
            || git fetch --quiet origin "$CARVE_SOURCE_SHA" 2>/dev/null \
            || { KEEP_WORKDIR=1; die "Could not fetch $CARVE_SOURCE_SHA from origin"; }
        git checkout --quiet "$CARVE_SOURCE_SHA" \
            || { KEEP_WORKDIR=1; die "Could not checkout $CARVE_SOURCE_SHA even after deepen-fetch"; }
    fi

    note "Verifying carve-out paths are PRESENT at pre-Phase-B SHA $CARVE_SOURCE_SHA"
    for path in "${CARVE_OUT[@]}"; do
        [[ -e "$path" ]] || { KEEP_WORKDIR=1; die "Carve-out path '$path' is absent at pre-Phase-B SHA $CARVE_SOURCE_SHA -- Phase B may have been squash-merged or the repo force-pushed. Re-run with --keep-workdir and inspect $WORK/source."; }
    done
    ok "All carve-out paths present at pre-Phase-B SHA $CARVE_SOURCE_SHA"

    if [[ $RECOVER -eq 0 ]]; then
        note "Creating empty $ORG/$NEW_REPO (GitHub side)"
        read -r -p "  Create $ORG/$NEW_REPO as a PUBLIC repo on GitHub? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] \
            || { KEEP_WORKDIR=1; die "aborted before gh repo create -- workdir preserved at $WORK/source"; }
        if ! gh repo create "$ORG/$NEW_REPO" \
                --public \
                --description "Agent-host plugins and skills imported by Claude Code / Codex / Pi. Carved out from Hephaestus per ADR-016." \
                --homepage "https://github.com/$ORG/Odysseus/blob/main/docs/adr/016-split-hephaestus.md" \
                --add-readme 2>&1 | tail -10; then
            KEEP_WORKDIR=1
            die "gh repo create failed; the empty repo may still have been created -- check the org before re-running"
        fi

        note "Cloning empty $ORG/$NEW_REPO"
        if ! gh repo clone "$ORG/$NEW_REPO" "$WORK/$NEW_REPO" 2>&1 | tail -5; then
            KEEP_WORKDIR=1
            die "gh repo clone $ORG/$NEW_REPO failed; repo exists but is empty -- inspect on the web before re-running"
        fi
        cd "$WORK/$NEW_REPO"
    else
        note "(--recover) Skipping gh repo create; cloning existing $ORG/$NEW_REPO into $WORK/$NEW_REPO"
        if ! gh repo clone "$ORG/$NEW_REPO" "$WORK/$NEW_REPO" 2>&1 | tail -5; then
            KEEP_WORKDIR=1
            die "gh repo clone $ORG/$NEW_REPO failed in --recover mode -- inspect the org before re-running"
        fi
        cd "$WORK/$NEW_REPO"
    fi
else
    note "(dry-run) would: clone $ORG/$SOURCE_REPO HEAD, create $ORG/$NEW_REPO, populate, push main"
fi

# ─── Phase 4: copy carve-out surface ─────────────────────────────
note "Phase 4 — copy carve-out surface"
if [[ $DRY_RUN -eq 0 ]]; then
    for path in "${CARVE_OUT[@]}"; do
        src="$WORK/source/$path"
        if [[ -e "$src" ]]; then
            note "  cp -R $path"
            # -p preserves mode, ownership, timestamps; -R recurses.
            # Without -p, executable bits in skills/ or symlinks in
            # plugins/ may silently strip.
            cp -Rp "$src" "$WORK/$NEW_REPO/$path"
        else
            note "  (skip) $path not in source"
        fi
    done
    ok "Carve-out surface copied"
fi

# ─── Phase 5: write Athena's own files ──────────────────────────
note "Phase 5 — write pyproject.toml + README.md + AGENTS.md + LICENSE + .gitignore"
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$WORK/$NEW_REPO/pyproject.toml" <<'PYEOF'
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "athena"
version = "0.1.0"
description = "Agent-host plugins and skills imported by Claude Code / Codex / Pi."
readme = "README.md"
requires-python = ">=3.10"
dependencies = ["hephaestus"]

[project.optional-dependencies]
automation = ["hephaestus[automation]"]

[tool.hatch.build.targets.wheel]
packages = ["."]
PYEOF

    cat > "$WORK/$NEW_REPO/README.md" <<READMEEOF
# Athena

Agent-host plugins and skills. Carved out from
[\`Hephaestus\`](https://github.com/HomericIntelligence/Hephaestus) per
[ADR-016](https://github.com/HomericIntelligence/Odysseus/blob/main/docs/adr/016-split-hephaestus.md).

## Install

- **Claude Code**: clone this repo and add to \`~/.claude/settings.json\`:
  \`\`\`json
  "enabledPlugins": { "athena@Athena": true }
  \`\`\`
- **Codex**: \`cp -R .codex-plugin/* ~/.codex/plugins/\`
- **Pi**: \`cp -R .agents/* ~/.pi/agents/\`

## Python dependency

Athena depends on Hephaestus. If a skill invokes the orchestrator pipeline,
install the automation extra:

\`\`\`bash
pip install athena[automation]
# Equivalent to: pip install hephaestus[automation]
\`\`\`

## Carve-out source

Initial commit of this repo was carved from
\`HomericIntelligence/Hephaestus@${SOURCE_SHA}\` by
\`scripts/migration/hephaestus-split/athena-create.sh\`.
READMEEOF

    cat > "$WORK/$NEW_REPO/AGENTS.md" <<'AGENTSEOF'
# AGENTS.md — Athena

> **AI agents:** Companion to \`Hephaestus/AGENTS.md\`. Athena is a
> *plugin/skill distribution* repo, not a library. It ships Claude Code,
> Codex, and Pi host-side plugins and skills. The **Python library code**
> that these skills interact with lives in \`Hephaestus\`.

## Dependency direction

- **Athena → Hephaestus (one-way).** Athena's \`pyproject.toml\` declares
  \`hephaestus\` (and the \`[automation]\` extra) as a dependency.
- **Hephaestus NEVER imports from Athena.** Library-side
  \`test_import_surface.py\` enforces this. Do not add any
  \`from athena\` / \`import athena\` statement under \`hephaestus/\`.

## Boundaries

- Anything under \`.claude-plugin/\`, \`.codex-plugin/\`, \`.agents/\`,
  \`plugins/\`, \`skills/\`, \`assets/\` — owned by Athena.
- Anything under \`hephaestus/*\` — owned by Hephaestus (NOT Athena).
  Skills that need orchestrator functionality do
  \`from hephaestus.automation import …\` from inside the skill body.

## Permitted tools

Bash, Read, Write, Edit, Glob, Grep (same as Hephaestus myrmidons).

## Prohibited actions

- Edit anything under \`hephaestus/\` — that lives in the Hephaestus repo.
- Add a Python package under \`hephaestus.*\` from this repo.
- Bump the Hephaestus pin in \`pyproject.toml\` without coordination
  (cross-repo integration event per Odysseus/AGENTS.md).
AGENTSEOF

    cat > "$WORK/$NEW_REPO/LICENSE" <<LICENSEEOF
Same license as \`HomericIntelligence/Hephaestus@${SOURCE_SHA}\` at carve-out time.
Individual license notices on copied assets are preserved in their files.
LICENSEEOF

    cat > "$WORK/$NEW_REPO/.gitignore" <<'GITIGNORE'
__pycache__/
*.py[cod]
*$py.class
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/
dist/
build/
.venv/
venv/
env/
GITIGNORE

    ok "Athena's files written"
fi

# ─── Phase 6: commit + push ─────────────────────────────────────
note "Phase 6 — commit + push to $ORG/$NEW_REPO main"
if [[ $DRY_RUN -eq 0 ]]; then
    cd "$WORK/$NEW_REPO"

    # Skip the initial auto-README cleanup in --recover mode (the existing
    # repo's initial commit may have already removed its README, and we
    # are not the ones who created it).  Also: the original used `warn`
    # which was never defined -- would crash under `set -u` if reached;
    # fixed to `note`.  See git history of this file.
    if [[ $RECOVER -eq 0 ]]; then
        # If gh repo create --add-readme produced an initial commit, reset to a clean tree
        if [[ -n "$(git status --porcelain 2>/dev/null || printf '')" || "$(git log --oneline | wc -l)" -gt 0 ]]; then
            note "  Cleaning initial auto-created README from --add-readme flag"
            if ! git rm -f README.md 2>/dev/null; then
                note "  README.md removal skipped (may already be absent)"
            fi
            if ! { git commit --allow-empty -m "chore: remove auto-created README placeholder" 2>&1 | tail -3; }; then
                note "  empty-commit step failed (may already be on initial empty commit)"
            fi
        fi
    else
        note "(--recover) Skipping initial auto-README cleanup"
    fi

    git add -A

    # Idempotency bail under --recover: cp -Rp reproduces identical
    # bytes, so if Athena main already contains the carve-out surface
    # `git add -A` is a no-op and `git commit` would abort with a
    # cryptic "nothing to commit" error.  Bail explicitly with a polite
    # note.  In default mode (fresh split), if `git add -A` is a no-op
    # that means Phase 4 silently failed to copy -- let that surface as
    # an error so the operator notices.
    if [[ $RECOVER -eq 1 ]]; then
        if git diff --cached --quiet; then
            ATHENA_LOCAL_HEAD=$(git rev-parse --short HEAD)
            ok "Athena main at ${ATHENA_LOCAL_HEAD} already contains the carve-out surface — idempotent exit; nothing to push"
            exit 0
        fi
    fi

    # Commit message varies by mode:
    #   - default (fresh split): "feat: initial carve-out of …"
    #   - --recover: notes this commit completes an earlier broken Phase C
    local _commit_msg
    if [[ $RECOVER -eq 1 ]]; then
        _commit_msg="feat(carve-out): complete Hephaestus→Athena migration (@ADR-016)

[RECOVERY commit — pushed onto existing Athena main]

Original Phase C of this script shipped Athena with only its hand-written
scaffolding files (pyproject.toml / AGENTS.md / LICENSE / .gitignore) and
silently skipped the carve-out copy because of a logical contradiction
(see scripts/migration/hephaestus-split/athena-create.sh). This commit
completes the carve-out by sourcing directly from Hephaestus@pre-Phase-B:

    Phase-B verified at:         ${SOURCE_SHA:-<unknown>} (carve-out paths absent)
    Pre-Phase-B copy source SHA: ${CARVE_SOURCE_SHA}
    Carve-out paths (6):         ${CARVE_OUT[*]}

Future --recover runs cite this commit as evidence the carve-out landed
correctly; the script was hardened in the same PR to walk git-log and
locate the pre-Phase-B SHA automatically (see --carve-source-sha).

Surface moved:   .claude-plugin/  .codex-plugin/  .agents/  plugins/  skills/  assets/
Stays in Hephaestus: hephaestus/ Python library, tests/, scripts/, docs/,
                    pyproject.toml, pixi.toml.

Dep direction: Athena depends on Hephaestus. The [automation] optional-dep
group keeps installing 'hephaestus[automation]' from the Hephaestus repo."
    else
        _commit_msg="feat: initial carve-out of agent-host plugins/skills from Hephaestus (@ADR-016)

Surface moved: .claude-plugin/  .codex-plugin/  .agents/  plugins/  skills/  assets/
Stays in Hephaestus: hephaestus/ Python library, tests/, scripts/, docs/,
                    pyproject.toml, pixi.toml.

Dep direction: Athena depends on Hephaestus. The [automation] optional-dep
group keeps installing 'hephaestus[automation]' from the Hephaestus repo.

Source commit: ${SOURCE_SHA}"
    fi
    if ! git commit -m "$_commit_msg" 2>&1 | tail -10; then
        KEEP_WORKDIR=1
        die "git commit failed"
    fi

    read -r -p "  Push to $ORG/$NEW_REPO/main? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] \
        || { KEEP_WORKDIR=1; die "aborted before push -- workdir preserved at $WORK/$NEW_REPO"; }

    if ! git push -u origin main 2>&1 | tail -10; then
        KEEP_WORKDIR=1
        die "git push failed -- workdir preserved at $WORK/$NEW_REPO"
    fi

    ok "Done. $ORG/$NEW_REPO main populated and pushed. Phase D (Odysseus meta-repo) is next."
else
    note "(dry-run) Plan preview complete. Re-run without --dry-run to execute."
fi
