#!/usr/bin/env bash
# Phase 80 — install or verify every repository's configured pre-commit hooks.
#
# The Python helper owns the security boundary.  This wrapper only selects the
# explicitly requested tools, translates structured results into the shared
# installer counters, and preserves sourced-versus-executed behavior.
# shellcheck disable=SC1091
set -uo pipefail

# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "Pre-commit Hooks"

finish_precommit_phase() {
    local result=0
    [[ "${_FAIL:-0}" -gt 0 ]] && result=1
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit "$result"
    fi
    return 0
}

python_binary=$(command -v python3 2>/dev/null || true)
git_binary=$(command -v git 2>/dev/null || true)
pre_commit_binary=${ODYSSEUS_PRECOMMIT_BINARY:-}
if [[ -z "$pre_commit_binary" ]]; then
    pre_commit_binary=$(command -v pre-commit 2>/dev/null || true)
fi
helper_path="$(dirname "${BASH_SOURCE[0]}")/precommit_hooks.py"

if [[ -z "$pre_commit_binary" ]]; then
    check_fail "pre-commit not found — install it first (pip install pre-commit)"
    finish_precommit_phase
    return 0
fi
if [[ -z "$python_binary" ]]; then
    check_fail "python3 not found — it is required to install hooks safely"
    finish_precommit_phase
    return 0
fi
if [[ -z "$git_binary" ]]; then
    check_fail "git not found — it is required to locate repository hooks"
    finish_precommit_phase
    return 0
fi
if [[ ! -f "$helper_path" ]]; then
    check_fail "pre-commit helper is missing: $helper_path"
    finish_precommit_phase
    return 0
fi

mode=check
[[ "${INSTALL:-false}" == "true" ]] && mode=install
helper_args=(
    --root "$ODYSSEUS_ROOT"
    --pre-commit "$pre_commit_binary"
    --git "$git_binary"
    --mode "$mode"
)
if [[ -n "${ODYSSEUS_PRECOMMIT_EXPECTED_VERSION:-}" ]]; then
    helper_args+=(--expected-version "$ODYSSEUS_PRECOMMIT_EXPECTED_VERSION")
fi

helper_output=$(env -i PATH=/usr/bin:/bin \
    "$python_binary" -I -S "$helper_path" "${helper_args[@]}" 2>&1)
helper_status=$?
reported_failure=false
while IFS=$'\t' read -r result_kind result_message; do
    [[ -z "$result_kind$result_message" ]] && continue
    case "$result_kind" in
        PASS) check_pass "$result_message" ;;
        FAIL) check_fail "$result_message"; reported_failure=true ;;
        WARN) check_warn "$result_message" ;;
        ACTION) echo -e "    ${BLUE}→${NC} $result_message" ;;
        *) check_warn "pre-commit helper: $result_kind${result_message:+ $result_message}" ;;
    esac
done <<< "$helper_output"
if [[ "$helper_status" -ne 0 && "$reported_failure" != true ]]; then
    check_fail "pre-commit hook setup failed without a structured diagnostic"
fi

finish_precommit_phase
