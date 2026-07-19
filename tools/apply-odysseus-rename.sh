#!/usr/bin/env bash
# ============================================================================
# tools/apply-odysseus-rename.sh
#
# Operator-driven automation for step 13 ("Odysseus-side finish") of the
# cross-repo rename documented in `docs/runbooks/rename-and-split.md`.
#
# Reads the canonical `Project<X>` → `<X>` rename map (matching runbook
# section 4 step-13) and rewrites, in one deterministic pass:
#   - .gitmodules (operator-gated; AGENTS.md forbids agent-driven pin bumps
#     but the operator is authorized)
#   - justfile
#   - docker-compose.e2e.yml
#   - tools/github/snapshot-protection.sh
#   - tools/github/remove-classic-protection.sh
#
# Files NEVER touched (always left for human follow-up):
#   - .github/workflows/* (require human review per AGENTS.md)
#   - submodule working trees (separate upstream repos)
#   - docs/adr/00*.md (append-only per AGENTS.md Key Principles item 3)
#
# USAGE
#   tools/apply-odysseus-rename.sh           # dry-run (DEFAULT; safe)
#   tools/apply-odysseus-rename.sh --check   # report only; no rewrite
#   tools/apply-odysseus-rename.sh --apply   # actually rewrite files
#
# PREREQUISITES for --apply
#   1. Steps 2–12 of the runbook complete upstream (all 11 upstream
#      `HomericIntelligence/Project<X>` renames merged + per-repo
#      internal-touch PRs merged).
#   2. Working tree clean (`git status --porcelain` empty).
#
# Style / safety conventions:
#   - Idempotent: runs over already-renamed files are no-ops (sed
#     expressions use word boundaries; nothing further to substitute).
#   - Pin-mode `--apply` aborts on dirty working tree.
#   - Dry-run prints unified diffs and exits 0 without writing.
#   - Out-of-scope files are listed in every output mode.
# ============================================================================

set -euo pipefail

# Rename map. Mirrors docs/runbooks/rename-and-split.md section 4 step-13
# table. Order is least-coupled-first → `ProjectAgamemnon` last (per
# runbook risk sequencing). Add new entries ONLY if a new ADR retired
# another `Project<X>` prefix; do not reorder without updating the
# runbook section 4 table.
REMAP=(
    # Order mirrors docs/runbooks/rename-and-split.md section 1 step 2->12
    # (least-coupled first, ProjectAgamemnon HMAS-orchestrator LAST).
    "ProjectMnemosyne:Mnemosyne"
    "ProjectTelemachy:Telemachy"
    "ProjectHermes:Hermes"
    "ProjectArgus:Argus"
    "ProjectScylla:Scylla"
    "ProjectOdyssey:Odyssey"
    "ProjectProteus:Proteus"
    "ProjectCharybdis:Charybdis"
    "ProjectKeystone:Keystone"
    "ProjectNestor:Nestor"
    "ProjectAgamemnon:Agamemnon"
)

# Files this script may rewrite. List is single-source of truth (mirrors
# the runbook section 4 step-13 enumeration).
SCOPE_FILES=(
    .gitmodules
    justfile
    docker-compose.e2e.yml
    tools/github/snapshot-protection.sh
    tools/github/remove-classic-protection.sh
    docs/architecture.md
    CLAUDE.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M1.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M2.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M3.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M4.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M5.md
    .github/PULL_REQUEST_TEMPLATE/atlas-M6.md
)

# Files NEVER touched by this script. Listed in every report so the
# operator knows what human-follow-up is still required.
OUT_OF_SCOPE=(
    ".github/workflows/* — requires human review per AGENTS.md"
    "submodule working trees — separate upstream repos; do not edit from meta-repo"
    "docs/adr/00*.md — append-only per AGENTS.md Key Principles item 3"
)

# Hyphen/underscore-prefix sanity guard.
#
# Word-boundary \b in GNU grep/sed MATCHES ACROSS '-' and '_' (both
# are \W). A scope file MUST NOT contain `Project<X>-foo` or
# `Project<X>_bar` tokens because the rewrite would replace only
# `Project<X>`, leaving the `-suffix` / `_suffix` stuck on the new
# name (e.g. `ProjectHermes-foo` → `Hermes-foo`, not the intended
# bare `Hermes`). The current meta-repo scope set has zero such
# prefix-affixed tokens, but the script guards against future scope
# expansion introducing one.
#
# Called by --apply (bail, exit 4) and dryrun (warn but proceed).
# Not called by --check (which is purely informational).
hyphen_sanity_check() {
    local hits
    # grep exits 1 on "no matches" — the expected/clean case here. Bracket the
    # capture with set +e/set -e so that expected-nonzero exit is treated as
    # control flow, not a masked failure (avoids the forbidden `|| true`).
    set +e
    hits=$(grep -nHE '\bProject[A-Z][a-zA-Z]+[-_]' "${SCOPE_FILES[@]}" 2>/dev/null)
    set -e
    if [ -n "$hits" ]; then
        echo "── Hyphen/underscore-prefix sanity FAILED ──" >&2
        echo "" >&2
        echo "$hits" >&2
        echo "" >&2
        echo "Word-boundary \b matches across '-' and '_' (both are \W)." >&2
        echo "The above lines contain tokens like 'ProjectX-foo' or 'ProjectX_bar'" >&2
        echo "that would be incorrectly rewritten. Resolve manually before" >&2
        echo "re-running --apply. (See code-reviewer note from commit 4c607b2.)" >&2
        return 1
    fi
    return 0
}

# Mode parsing. Default is dry-run.
MODE="dryrun"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
    "")      MODE="dryrun" ;;
    -h|--help)
        sed -n '2,38p' "$0"
        exit 0
        ;;
    *)       echo "Usage: $0 [--apply|--check]" >&2; exit 2 ;;
esac

# Operate from the meta-repo root regardless of the script's location.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Build a single semicolon-joined sed program from the REMAP table.
# (When SED_EXPR was a bash array expanded via "${SED_EXPR[@]}", sed
# treated each entry as a separate INPUT FILE. Joining with ';' passes
# it as ONE program arg.) \b requires GNU sed BRE engine.
SED_PROG=""
for entry in "${REMAP[@]}"; do
    old="${entry%%:*}"
    new="${entry##*:}"
    SED_PROG+="s/\\b${old}\\b/${new}/g;"
done

echo "Mode: $MODE"
echo "Mappings (${#REMAP[@]}):"
for entry in "${REMAP[@]}"; do
    echo "  $entry"
done
echo

# Helper: count stale Project<X> token matches per file (number only).
report_stale_counts() {
    local f n
    for f in "$@"; do
        [ -f "$f" ] || { printf "  %-60s %s\n" "$f" "(absent)"; continue; }
        # grep -c prints 0 and exits 1 when there are no matches (the clean
        # case). Bracket the capture so the expected-nonzero exit is control
        # flow, not a masked failure (avoids the forbidden `|| true`).
        set +e
        n=$(grep -cE '\bProject[A-Z][a-zA-Z]+\b' "$f")
        set -e
        if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
            printf "  %-60s %s hits\n" "$f" "$n"
        else
            printf "  %-60s %s\n" "$f" "(clean)"
        fi
    done
}

# Helper: print out-of-scope note (used in every mode).
print_out_of_scope() {
    echo "── Out of scope (NEVER touched by this script) ──"
    for note in "${OUT_OF_SCOPE[@]}"; do
        echo "  $note"
    done
    echo
}

case "$MODE" in
    check)
        echo "── Stale Project<X> refs in scope files ──"
        report_stale_counts "${SCOPE_FILES[@]}"
        echo
        print_out_of_scope
        echo "CHECK complete (no files modified)."
        exit 0
        ;;
    dryrun)
        echo "── Hyphen/underscore-prefix sanity ──"
        if ! hyphen_sanity_check; then
            echo "  (continuing dry-run; --apply would refuse; see code-reviewer note from commit 4c607b2)"
        else
            echo "  clean (no \`ProjectX-\` / \`ProjectX_\` tokens found in scope files)"
        fi
        echo
        echo "── Stale Project<X> refs in scope files (count) ──"
        report_stale_counts "${SCOPE_FILES[@]}"
        echo
        echo "── Proposed substitutions (unified-diff preview) ──"
        local_changes=0
        for f in "${SCOPE_FILES[@]}"; do
            [ -f "$f" ] || continue
            local_tmp=$(mktemp)
            sed "$SED_PROG" "$f" > "$local_tmp"
            if ! diff -q "$f" "$local_tmp" >/dev/null 2>&1; then
                echo "── diff: $f ──"
                # diff exits 1 when files differ — which they always do here
                # (we only reach this branch after `! diff -q` above). Bracket
                # the capture so the expected-nonzero exit is control flow, not
                # a masked failure (avoids the forbidden `|| true`).
                set +e
                full_diff=$(diff -u "$f" "$local_tmp")
                set -e
                diff_lines=$(printf '%s\n' "$full_diff" | wc -l)
                printf '%s\n' "$full_diff" | head -80
                if [ "${diff_lines:-0}" -gt 80 ]; then
                    echo "    (diff truncated — showing 80 of ${diff_lines} lines; for full diff, redirect stdout: 'tools/apply-odysseus-rename.sh 2>/dev/null > rename.diff')"
                fi
                local_changes=$((local_changes + 1))
            fi
            rm -f "$local_tmp"
        done
        echo
        if [ "$local_changes" -eq 0 ]; then
            echo "(no rewrites proposed — all scope files are already clean)"
        else
            echo "($local_changes file(s) would change)"
        fi
        echo
        print_out_of_scope
        echo "DRY-RUN complete (no files modified). Re-run with --apply to commit."
        exit 0
        ;;
    apply)
        # `grep -v` exits 1 when it filters out every line (i.e. the tree is
        # clean apart from untracked files) — the expected case. Capture the
        # tracked-change list under a set +e/set -e bracket so that expected
        # exit is control flow, then test it (avoids the forbidden `|| true`).
        set +e
        tracked_changes=$(git status --porcelain 2>/dev/null | grep -v '^??')
        set -e
        if [ -n "$tracked_changes" ]; then
            echo "ERROR: working tree has uncommitted changes. Commit or stash first." >&2
            git status --short
            exit 3
        fi
        # Hyphen/underscore-prefix sanity guard: bail before any rewrite
        # (exit 4) if scope files contain 'Project<X>-' or 'Project<X>_'
        # tokens that would be incorrectly rewritten.
        if ! hyphen_sanity_check; then
            exit 4
        fi
        echo "── Applying rewrites ──"
        applied=0
        for f in "${SCOPE_FILES[@]}"; do
            [ -f "$f" ] || continue
            cp "$f" "$f.bak-pre-rename"
            sed -i "$SED_PROG" "$f"
            if diff -q "$f.bak-pre-rename" "$f" >/dev/null 2>&1; then
                # No change; remove the unnecessary backup.
                rm -f "$f.bak-pre-rename"
                echo "  (unchanged) $f"
            else
                echo "  rewrote:    $f  (backup at $f.bak-pre-rename)"
                applied=$((applied + 1))
            fi
        done
        echo
        echo "── Applied to $applied file(s) ──"
        echo
        echo "── Next steps (operator, per AGENTS.md) ──"
        echo "  1. Inspect: git diff"
        echo "  2. Verify upstream renames: for each \\`<X>\\` in REMAP, run"
        echo "       git ls-remote https://github.com/HomericIntelligence/<X>.git"
        echo "     (must return a non-empty commit hash)."
        echo "  3. Regenerate ecosystem CI table:"
        echo "       just ecosystem-table"
        echo "  4. Drop backups once the diff is reviewed:"
        echo "       find . -maxdepth 3 -name '*.bak-pre-rename' -delete"
        echo "  5. Open the meta-repo finish PR per docs/runbooks/rename-and-split.md"
        echo "     section 4 — operator (you) merges by hand (NOT auto-merge; AGENTS.md"
        echo "     forbids auto-merge for cross-repo integration PRs)."
        ;;
esac
