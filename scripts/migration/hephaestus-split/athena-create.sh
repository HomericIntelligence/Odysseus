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
# Refuses to run if a `HomericIntelligence/Athena` repo already exists
# (one-shot operation).
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

usage() {
    cat <<USAGE
Usage: $(basename "$0") [flags]

Phase C of the ProjectHephaestus → Hephaestus + Athena split. Run AFTER
Phase B (hephaestus-prune-pr.sh) PR is merged onto Hephaestus main.

Flags:
    --dry-run           Print every command that would run; do not write.
    --keep-workdir      Leave /tmp/athena-create-* on exit (for inspection).
    --source-sha SHA    Pin the source commit (default: source HEAD).
    --help              Show this help.
USAGE
}

die()  { printf '  ERROR  %s\n' "$*" >&2; exit 1; }
note() { printf '  ----   %s\n' "$*"; }
ok()   { printf '  OK     %s\n' "$*"; }

# ─── Argument parsing ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --keep-workdir)   KEEP_WORKDIR=1; shift ;;
        --source-sha)     SOURCE_SHA="${2:-}"; shift 2 || die "--source-sha requires a value" ;;
        --help|-h)        usage; exit 0 ;;
        *)                die "Unknown argument: $1 (try --help)" ;;
    esac
done

# SHA must be hex; cheap regex over [0-9a-f]{7,40}
# SHA must be hex; accept uppercase or lowercase (git short SHAs are case-insensitive)
[[ -z "$SOURCE_SHA" || "$SOURCE_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] \
    || die "--source-sha '$SOURCE_SHA' is not a hex commit identifier"

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
    die "$ORG/$NEW_REPO already exists. Either Phase C is already done or the repo was created manually. Refusing to overwrite."
fi
ok "Preflight OK"

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
    note "(dry-run) would: clone $ORG/$SOURCE_REPO HEAD, create $ORG/$NEW_REPO, populate, push main"
fi

# ─── Phase 4: copy carve-out surface ─────────────────────────────
note "Phase 4 — copy carve-out surface"
if [[ $DRY_RUN -eq 0 ]]; then
    for path in "${CARVE_OUT[@]}"; do
        src="$WORK/source/$path"
        if [[ -e "$src" ]]; then
            note "  cp -R $path"
            cp -R "$src" "$WORK/$NEW_REPO/$path"
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

    # If gh repo create --add-readme produced an initial commit, reset to a clean tree
    if [[ -n "$(git status --porcelain 2>/dev/null || printf '')" || "$(git log --oneline | wc -l)" -gt 0 ]]; then
        note "  Cleaning initial auto-created README from --add-readme flag"
        if ! git rm -f README.md 2>/dev/null; then
            warn "README.md removal skipped (may already be absent)"
        fi
        if ! { git commit --allow-empty -m "chore: remove auto-created README placeholder" 2>&1 | tail -3; }; then
            warn "empty-commit step failed (may already be on initial empty commit)"
        fi
    fi

    git add -A
    if ! git commit -m "feat: initial carve-out of agent-host plugins/skills from Hephaestus (@ADR-016)

Surface moved: .claude-plugin/  .codex-plugin/  .agents/  plugins/  skills/  assets/
Stays in Hephaestus: hephaestus/ Python library, tests/, scripts/, docs/,
                    pyproject.toml, pixi.toml.

Dep direction: Athena depends on Hephaestus. The [automation] optional-dep
group keeps installing 'hephaestus[automation]' from the Hephaestus repo.

Source commit: ${SOURCE_SHA}" 2>&1 | tail -10; then
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
