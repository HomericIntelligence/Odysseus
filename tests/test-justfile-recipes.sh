#!/usr/bin/env bash
# Integration tests for Odysseus justfile recipe integrity (issue #198).
# Build-free: no compilation, NATS, podman, or submodules required.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT"

info "justfile parse round-trip"
if just --summary >/dev/null 2>&1; then pass "just --summary parses"; else fail "just --summary failed"; fi
if just --list >/dev/null 2>&1; then pass "just --list parses"; else fail "just --list failed"; fi

info "canonical recipes documented in AGENTS.md exist"
mapfile -t recipes < <(just --summary | tr ' ' '\n' | sort -u)
for r in bootstrap status update-submodules apply-all hermes-start \
         argus-start telemachy-run validate-configs ci \
         validate-nats validate-compose test-justfile-recipes; do
    if printf '%s\n' "${recipes[@]}" | grep -qx "$r"; then
        pass "recipe present: $r"
    else
        fail "recipe MISSING: $r"
    fi
done

summary
exit_code   # e2e/lib/common.sh:41 -- returns non-zero if any fail
