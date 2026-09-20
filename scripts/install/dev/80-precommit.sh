#!/bin/bash
# Phase 80 — install or verify every repository's configured pre-commit hooks.
#
# The Python helper owns the security boundary.  This wrapper only selects the
# explicitly requested tools, translates structured results into the shared
# installer counters, and preserves sourced-versus-executed behavior.
# shellcheck disable=SC1091
set -uo pipefail

wrapper_source=${BASH_SOURCE[0]}
case "$wrapper_source" in
    */*) wrapper_dir=${wrapper_source%/*} ;;
    *) wrapper_dir=. ;;
esac
if ! wrapper_dir=$(builtin cd -P -- "$wrapper_dir" && builtin pwd -P); then
    printf 'ERROR: cannot resolve the pre-commit installer directory\n' >&2
    exit 1
fi
if [[ -z "${ODYSSEUS_ROOT:-}" ]]; then
    if ! ODYSSEUS_ROOT=$(builtin cd -P -- "$wrapper_dir/../../.." && builtin pwd -P); then
        printf 'ERROR: cannot resolve the Odysseus repository root\n' >&2
        exit 1
    fi
    export ODYSSEUS_ROOT
fi

# shellcheck source=../lib.sh
builtin source "$wrapper_dir/../lib.sh"

section "Pre-commit Hooks"

finish_precommit_phase() {
    local result=0
    [[ "${_FAIL:-0}" -gt 0 ]] && result=1
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exit "$result"
    fi
    return 0
}

python_binary=/usr/bin/python3
git_binary=/usr/bin/git
pre_commit_binary=${ODYSSEUS_PRECOMMIT_BINARY:-}
if [[ -z "$pre_commit_binary" ]]; then
    if ! pre_commit_binary=$(builtin command -v pre-commit 2>/dev/null); then
        pre_commit_binary=""
    fi
fi
helper_path="$wrapper_dir/precommit_hooks.py"

if [[ -z "$pre_commit_binary" ]]; then
    check_fail "pre-commit not found — install it first (pip install pre-commit)"
    finish_precommit_phase
    return 0
fi
if [[ ! -x "$python_binary" ]]; then
    check_fail "python3 not found — it is required to install hooks safely"
    finish_precommit_phase
    return 0
fi
if [[ ! -x "$git_binary" ]]; then
    check_fail "git not found — it is required to locate repository hooks"
    finish_precommit_phase
    return 0
fi
if [[ ! -e "$helper_path" ]]; then
    check_fail "pre-commit helper is missing: $helper_path"
    finish_precommit_phase
    return 0
fi
if [[ ! -f "$helper_path" || -L "$helper_path" ]]; then
    check_fail "pre-commit helper is not one direct regular file: $helper_path"
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

helper_output=$(/usr/bin/env -i PATH=/usr/bin:/bin \
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
