#!/usr/bin/env bash
# tools/propagate-pre-commit-hooks.sh
#
# Propagates the meta-repo's `.githooks/pre-commit` banlist + 512 KiB +
# signing hook into every initialized submodule's default hooks directory
# (`.git/modules/<submodule>/hooks/pre-commit`).
#
# Why this script exists
# ----------------------
# The meta-repo's pre-commit hook (banlist patterns + 512 KiB large-file
# guard + remediation hints) is canonical for the meta-repo itself. But
# when a developer commits from INSIDE a submodule directory — e.g. to
# fix a bug in HomericIntelligence/ProjectArgus — git consults that
# submodule's OWN `core.hooksPath`. If the submodule repo doesn't set
# `core.hooksPath`, the default is the meta-repo-controlled directory
# `.git/modules/<submodule>/hooks/pre-commit`. This script copies the
# meta-repo hook into that default location so the same protections
# extend into submodule work WITHOUT requiring each submodule repo to
# set `core.hooksPath` (which would mean changes IN each submodule).
#
# Policy compliance with AGENTS.md
# ---------------------------------
# AGENTS.md states submodule WORKING TREES are read-only for meta-repo
# agents — changes belong in each submodule's own repo. This script
# writes only into the meta-repo's `.git/modules/<submodule>/hooks/`
# directory. That path lives in the META-REPO's `.git/` (not the
# submodule working tree), so the policy still applies — but the hook
# directory is meta-repo territory and IS safe to manage here.
# Submodule `core.hooksPath` is NOT set — if/when a submodule repo
# chooses its own hook layout, its setting takes precedence (correct
# behavior). The script does not modify any submodule's git config.
#
# Idempotency
# -----------
# Running twice is safe; the destination is overwritten atomically.
# The `--dry-run` mode shows what would change without writing.
# The `--verify` mode confirms each installed hook still matches the source.
#
# Uninitialized submodules
# ------------------------
# Submodules that haven't been `git submodule update --init`'d yet are
# SKIPPED (their `.git/modules/<path>/` directory doesn't exist).
# The script reports them so you can initialize then re-run.
#
# Usage
# -----
#   tools/propagate-pre-commit-hooks.sh            # live copy + verify
#   tools/propagate-pre-commit-hooks.sh --dry-run  # show what would happen
#   tools/propagate-pre-commit-hooks.sh --verify   # check post-install state
#   tools/propagate-pre-commit-hooks.sh --help     # show this help

set -euo pipefail

# Resolve meta-repo root (script lives in /tools/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_HOOK="$META_ROOT/.githooks/pre-commit"

# Parse args
DRY_RUN=0
VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --verify)   VERIFY_ONLY=1 ;;
        --help|-h)
            # --help goes to STDERR by design: prevents accidental pollution of
            # `script --dry-run | tee propagation.log` pipelines where stdout is
            # the report. Users capturing help explicitly with `script --help
            # 2>&1 | less` still see it; terminals always show stderr.
            cat <<'EOF' >&2
Usage: tools/propagate-pre-commit-hooks.sh [--dry-run | --verify | --help]

Propagates the meta-repo's .githooks/pre-commit into each initialized
submodule's default hooks directory (.git/modules/<sub>/hooks/pre-commit).

  (default)    live copy + per-submodule report to stdout
  --dry-run    plan copy operations; no filesystem changes
  --verify     check each installed hook matches source; exit 1 on stale
  --help       print this help and exit 0

Exit codes:
  0   success (or dry-run / help)
  1   --verify found stale or absent, OR live copy failed for >=1 submodule
  2   argument error or missing source hook / .gitmodules

See the file's leading docstring (lines after the shebang) for the full
rationale, idempotency notes, AGENTS.md policy compliance discussion,
and uninitialized-submodule recovery steps.
EOF
            exit 0
            ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Pre-flight
if [ ! -f "$SRC_HOOK" ]; then
    echo "ERROR: source hook not found: $SRC_HOOK" >&2
    echo "       Run from the meta-repo root or fix the path." >&2
    exit 2
fi

if [ ! -f "$META_ROOT/.gitmodules" ]; then
    echo "ERROR: .gitmodules not found in $META_ROOT" >&2
    exit 2
fi

# ISO-like timestamp for the propagation report
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SRC_HASH=$(sha256sum "$SRC_HOOK" | awk '{print $1}')

# Counters. The `stale` bucket is dual-purpose by design:
#   - in --verify mode: destination differs from source (or is absent)
#   - in live mode:    copy/chmod/mv/diff failed for that submodule
# It always means "this submodule needs attention before claiming success."
total=0
copied=0
verified=0
skipped=0
stale=0

# Report buffer: report lines + JSONL sidecar
report=""
report_lines=()

# Extract submodule paths from .gitmodules (only `path = ...` lines that
# follow a `[submodule ...]` stanza). Handles mixed tabs/spaces.
while IFS= read -r sm_path; do
    [ -z "$sm_path" ] && continue
    total=$((total + 1))

    dst_rel=".git/modules/$sm_path/hooks/pre-commit"
    dst="$META_ROOT/$dst_rel"

    # Get submodule status symbol: ' ', '-', '+', 'U'
    sm_status=$(git -C "$META_ROOT" submodule status "$sm_path" 2>/dev/null | head -1 | awk '{print $1}')

    if [ ! -d "$META_ROOT/.git/modules/$sm_path" ]; then
        report_lines+=("[skip]   $sm_path  (not initialized; run: git submodule update --init --recursive)")
        skipped=$((skipped + 1))
        continue
    fi

    mkdir -p "$META_ROOT/.git/modules/$sm_path/hooks"

    if [ "$VERIFY_ONLY" -eq 1 ]; then
        if [ -f "$dst" ] && diff -q "$SRC_HOOK" "$dst" >/dev/null 2>&1; then
            mode=$(stat -c %a "$dst" 2>/dev/null || stat -f %Lp "$dst" 2>/dev/null || echo "?")
            report_lines+=("[ok]     $sm_path  (sha256 matches; mode=$mode)")
            verified=$((verified + 1))
        elif [ -f "$dst" ]; then
            report_lines+=("[stale]  $sm_path  (destination differs from source; re-run to refresh)")
            stale=$((stale + 1))
        else
            report_lines+=("[absent] $sm_path  (hook not installed; re-run to install)")
            stale=$((stale + 1))
        fi
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        mode=$(stat -c %a "$dst" 2>/dev/null || stat -f %Lp "$dst" 2>/dev/null || echo "(none)")
        report_lines+=("[plan]   $sm_path -> $dst_rel  (current mode=$mode, submodule-status='$sm_status')")
        continue
    fi

    # Live copy: atomic via tmpfile + rename, then chmod, then verify
    tmp_dst="${dst}.tmp.$$"
    if cp -f "$SRC_HOOK" "$tmp_dst" 2>/tmp/propagate-cp.err \
       && chmod 0755 "$tmp_dst" \
       && mv -f "$tmp_dst" "$dst" \
       && diff -q "$SRC_HOOK" "$dst" >/dev/null 2>&1; then
        mode=$(stat -c %a "$dst" 2>/dev/null || stat -f %Lp "$dst" 2>/dev/null || echo "?")
        report_lines+=("[copy]   $sm_path -> $dst_rel  (mode=$mode, sha256 matches)")
        copied=$((copied + 1))
    else
        rm -f "$tmp_dst" 2>/dev/null || true
        err=$(cat /tmp/propagate-cp.err 2>/dev/null || echo "(no error captured)")
        report_lines+=("[FAIL]   $sm_path  (cp/chmod/mv/diff failed; $err)")
        # Don't increment `copied`; will exit non-zero at end if needed
        stale=$((stale + 1))
    fi
done < <(awk '
    /^\[submodule[[:space:]]+/ { flag = 1; next }
    flag && /^[[:space:]]*path[[:space:]]*=/ {
        sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "")
        print
        flag = 0
    }
' "$META_ROOT/.gitmodules")

# Output
echo "=== tools/propagate-pre-commit-hooks.sh ==="
echo "timestamp:        $TS"
echo "source hook:      $SRC_HOOK"
echo "source sha256:    $SRC_HASH"
echo "mode:             $([ $DRY_RUN -eq 1 ] && echo dry-run || ([ $VERIFY_ONLY -eq 1 ] && echo verify || echo live))"
echo
echo "--- per-submodule status ---"
for line in "${report_lines[@]}"; do
    echo "$line"
done
echo "--- end ---"
echo

# Summary
echo "=== SUMMARY ==="
echo "total submodules parsed:       $total"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry run; nothing copied)"
elif [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "verified (matches source):    $verified"
    echo "stale or absent:              $stale"
    echo "skipped (uninitialized):      $skipped"
else
    echo "copied (live):                $copied"
    echo "stale or failed (live):       $stale"
    echo "skipped (uninitialized):      $skipped"
fi

# Hint
if [ "$skipped" -gt 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    echo
    echo "Some submodules are uninitialized. To populate then re-run:"
    echo "  git submodule update --init --recursive"
    echo "  ./tools/propagate-pre-commit-hooks.sh --verify"
fi

# Non-zero exit on --verify if anything is stale/absent
if [ "$VERIFY_ONLY" -eq 1 ] && [ "$stale" -gt 0 ]; then
    exit 1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] && [ "$stale" -gt 0 ]; then
    exit 1
fi
exit 0
