#!/usr/bin/env bash
# Behavior checks for the read-only Code Quality discovery probe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

fixture_prefix="${TMPDIR:-/tmp}/odysseus-code-quality."
fixture_root=""
fixture_root_valid=false

make_fixture_directory() {
    local prefix="$1" created suffix
    if ! created="$(mktemp -d "${prefix}XXXXXX")"; then
        return 1
    fi
    suffix="${created#"$prefix"}"
    if [ -z "$created" ] || [ "$suffix" = "$created" ] || [ -z "$suffix" ] \
        || [ ! -d "$created" ] || [ -L "$created" ]; then
        return 1
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s\n' "$created"
}

if ! fixture_root="$(make_fixture_directory "$fixture_prefix")"; then
    printf '%s\n' 'ERROR: could not create a safe Code Quality fixture' >&2
    exit 1
fi
fixture_root_valid=true
fixture_bin="$fixture_root/bin"
gh_log="$fixture_root/gh.log"
git_log="$fixture_root/git.log"
unset BASH_ENV PYTHONPATH ODYSSEUS_TEST_SWAP_LSTAT_TARGET \
    ODYSSEUS_TEST_SWAP_ORIGINAL ODYSSEUS_TEST_SWAP_VICTIM \
    ODYSSEUS_TEST_SWAP_PARENT_TARGET ODYSSEUS_TEST_SWAP_PARENT_ORIGINAL \
    ODYSSEUS_TEST_SWAP_PARENT_VICTIM \
    ODYSSEUS_TEST_GIT_INVENTORY_MODE ODYSSEUS_TEST_GIT_URL_MODE
PROBE_SHELL="${ODYSSEUS_TEST_SHELL:-$BASH}"
PROBE_BASH_VERSION="$("$PROBE_SHELL" -c \
    'printf "%s.%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"')"
escape_character="$(printf '\033')"
mkdir -p "$fixture_bin"
cleanup_fixture() {
    local suffix
    [ "$fixture_root_valid" = true ] || return
    suffix="${fixture_root#"$fixture_prefix"}"
    if [ -z "$fixture_root" ] || [ "$suffix" = "$fixture_root" ] \
        || [ -z "$suffix" ] || [ ! -d "$fixture_root" ] \
        || [ -L "$fixture_root" ]; then
        echo "ERROR: refusing unsafe Code Quality fixture cleanup: $fixture_root" >&2
        return
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*)
            echo "ERROR: refusing unsafe Code Quality fixture cleanup: $fixture_root" >&2
            return
            ;;
    esac
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove Code Quality fixture: $fixture_root" >&2
    fi
}
trap cleanup_fixture EXIT
for tool in awk bash date jq mktemp mv python3 rm sed sort; do
    ln -s "$(command -v "$tool")" "$fixture_bin/$tool"
done

cat > "$fixture_bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ODYSSEUS_TEST_GIT_LOG:?}"
emit_paths() {
    case "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" in
        valid|duplicate-url-entry|partial-inventory|partial-url-inventory)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon'
            ;;
        duplicate-name)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon' \
              'submodule.control.Agamemnon.path alternate/Agamemnon'
            ;;
        duplicate-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agents' \
              'submodule.control.Nestor.path control/Agents'
            ;;
        missing-url|duplicate-repo-url)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon' \
              'submodule.control.Nestor.path control/Nestor'
            ;;
        orphan-url)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon' \
              'submodule.control.Nestor.path control/Nestor'
            ;;
        dot-name)
            printf '%s\n' \
              'submodule.control/./Agamemnon.path control/Agamemnon'
            ;;
        dot-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/./Agamemnon'
            ;;
        leading-dot-name)
            printf '%s\n' \
              'submodule../Agamemnon.path control/Agamemnon'
            ;;
        terminal-dot-name)
            printf '%s\n' \
              'submodule.control/Agamemnon/..path control/Agamemnon'
            ;;
        trailing-slash-name)
            printf '%s\n' \
              'submodule.control/Agamemnon/.path control/Agamemnon'
            ;;
        leading-dot-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.path ./control/Agamemnon'
            ;;
        terminal-dot-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon/.'
            ;;
        trailing-slash-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.path control/Agamemnon/'
            ;;
        *) exit 89 ;;
    esac
}

emit_urls() {
    if [ "${ODYSSEUS_TEST_GIT_URL_MODE:-valid}" != valid ]; then
        case "$ODYSSEUS_TEST_GIT_URL_MODE" in
            nested) url='https://github.com/HomericIntelligence/team/Agamemnon.git' ;;
            prefix) url='prefix-https://github.com/HomericIntelligence/Agamemnon.git' ;;
            suffix) url='https://github.com/HomericIntelligence/Agamemnon.git?ref=main' ;;
            scheme) url='http://github.com/HomericIntelligence/Agamemnon.git' ;;
            host) url='https://example.com/HomericIntelligence/Agamemnon.git' ;;
            org) url='https://github.com/OtherOrg/Agamemnon.git' ;;
            pipe) url='https://github.com/HomericIntelligence/Agamemnon|malicious.git' ;;
            *) exit 90 ;;
        esac
        printf 'submodule.control.Agamemnon.url %s\n' "$url"
        return
    fi
    case "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" in
        valid|duplicate-path|missing-url|partial-inventory|partial-url-inventory)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git'
            [ "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" != duplicate-path ] || \
                printf '%s\n' \
                  'submodule.control.Nestor.url https://github.com/HomericIntelligence/Nestor.git'
            ;;
        duplicate-name)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git' \
              'submodule.control.Orphan.url https://github.com/HomericIntelligence/Orphan.git'
            ;;
        duplicate-url-entry)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Nestor.git'
            ;;
        orphan-url)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git' \
              'submodule.control.Orphan.url https://github.com/HomericIntelligence/Orphan.git'
            ;;
        duplicate-repo-url)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git' \
              'submodule.control.Nestor.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        dot-name)
            printf '%s\n' \
              'submodule.control/./Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        dot-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        leading-dot-name)
            printf '%s\n' \
              'submodule../Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        terminal-dot-name)
            printf '%s\n' \
              'submodule.control/Agamemnon/..url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        trailing-slash-name)
            printf '%s\n' \
              'submodule.control/Agamemnon/.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        leading-dot-path|terminal-dot-path|trailing-slash-path)
            printf '%s\n' \
              'submodule.control.Agamemnon.url https://github.com/HomericIntelligence/Agamemnon.git'
            ;;
        *) exit 89 ;;
    esac
}

case "${1:-}" in
    rev-parse)
        printf '%s\n' "${ODYSSEUS_TEST_REPO_ROOT:?}"
        ;;
    config)
        [ "$#" -eq 5 ] \
            && [ "${2:-}" = --file ] \
            && [ "${3:-}" = "$ODYSSEUS_TEST_REPO_ROOT/.gitmodules" ] \
            && [ "${4:-}" = --get-regexp ] \
            && [ "${5:-}" = '^submodule\..*\.(path|url)$' ] \
            || exit 90
        [ "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" != unavailable-inventory ] \
            || exit 88
        emit_paths
        [ "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" != partial-inventory ] \
            || exit 88
        emit_urls
        [ "${ODYSSEUS_TEST_GIT_INVENTORY_MODE:-valid}" != partial-url-inventory ] \
            || exit 88
        ;;
    *)
        exit 91
        ;;
esac
EOF
chmod +x "$fixture_bin/git"
export ODYSSEUS_TEST_GIT_LOG="$git_log"

python_hooks="$fixture_root/python-hooks"
mkdir -p "$python_hooks"
cat > "$python_hooks/sitecustomize.py" <<'PY'
import os


real_lstat = os.lstat
real_replace = os.replace
real_symlink = os.symlink
parent_swapped = False
swapped = False


def hooked_replace(source, destination, *, src_dir_fd=None, dst_dir_fd=None):
    global parent_swapped
    target = os.environ.get("ODYSSEUS_TEST_SWAP_PARENT_TARGET", "")
    if not parent_swapped and target:
        parent_swapped = True
        original = os.environ["ODYSSEUS_TEST_SWAP_PARENT_ORIGINAL"]
        victim = os.environ["ODYSSEUS_TEST_SWAP_PARENT_VICTIM"]
        real_replace(target, original)
        real_symlink(victim, target)
        if src_dir_fd is None and dst_dir_fd is None:
            source_name = os.path.basename(os.fsdecode(source))
            real_replace(
                os.path.join(original, source_name),
                os.path.join(victim, source_name),
            )
    if src_dir_fd is None and dst_dir_fd is None:
        return real_replace(source, destination)
    return real_replace(
        source,
        destination,
        src_dir_fd=src_dir_fd,
        dst_dir_fd=dst_dir_fd,
    )


def hooked_lstat(path, *, dir_fd=None):
    global swapped
    target = os.environ.get("ODYSSEUS_TEST_SWAP_LSTAT_TARGET", "")
    try:
        if dir_fd is None:
            result = real_lstat(path)
        else:
            result = real_lstat(path, dir_fd=dir_fd)
    except FileNotFoundError:
        if not swapped and target and os.fsdecode(path) == target:
            swapped = True
            real_symlink(
                os.environ["ODYSSEUS_TEST_SWAP_VICTIM"], path,
                dir_fd=dir_fd,
            )
        raise
    if not swapped and target and os.fsdecode(path) == target:
        swapped = True
        original = os.environ.get("ODYSSEUS_TEST_SWAP_ORIGINAL", "")
        if original:
            if dir_fd is None:
                real_replace(path, original)
            else:
                real_replace(
                    path, original,
                    src_dir_fd=dir_fd, dst_dir_fd=dir_fd,
                )
        real_symlink(
            os.environ["ODYSSEUS_TEST_SWAP_VICTIM"], path,
            dir_fd=dir_fd,
        )
    return result


os.lstat = hooked_lstat
os.replace = hooked_replace
PY

cat > "$fixture_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${ODYSSEUS_TEST_GH_LOG:?}"
case "${1:-}" in
    repo)
        [ "${2:-}" = list ] || exit 92
        [ "${ODYSSEUS_TEST_GH_MODE:-}" != inventory-unavailable ] || exit 97
        if [ "${ODYSSEUS_TEST_GH_MODE:-}" = unsafe-inventory ]; then
            printf '%s\n' Alpha 'bad|repo'
        elif [ "${ODYSSEUS_TEST_GH_MODE:-}" = duplicate-inventory ]; then
            printf '%s\n' Alpha Alpha
        else
            printf '%s\n' Beta Alpha
        fi
        ;;
    api)
        if [ "${2:-}" = --paginate ]; then
            endpoint="${3:-}"
        else
            endpoint="${2:-}"
        fi
        case "$endpoint" in
            orgs/HomericIntelligence/repos\?per_page=100\&type=all)
                [ "${ODYSSEUS_TEST_GH_MODE:-}" != inventory-unavailable ] || exit 97
                if [ "${ODYSSEUS_TEST_GH_MODE:-}" = unsafe-inventory ]; then
                    printf '%s\n' Alpha 'bad|repo'
                elif [ "${ODYSSEUS_TEST_GH_MODE:-}" = duplicate-inventory ]; then
                    printf '%s\n' Alpha Alpha
                else
                    printf '%s\n' Beta Alpha
                fi
                ;;
            repos/HomericIntelligence/*/code-scanning/default-setup)
                [ "${ODYSSEUS_TEST_GH_MODE:-}" != unavailable ] || exit 93
                case "${ODYSSEUS_TEST_GH_MODE:-}" in
                    cs-not-configured) printf '%s\n' not-configured ;;
                    cs-unknown) printf '%s\n' unknown ;;
                    cs-control) printf 'configured\033[31m\n' ;;
                    cs-newline) printf 'configured\nmalicious-row\n' ;;
                    cs-pipe) printf '%s\n' 'configured|malicious-cell' ;;
                    *) printf '%s\n' configured ;;
                esac
                ;;
            repos/HomericIntelligence/*/code-quality)
                [ "${ODYSSEUS_TEST_GH_MODE:-}" != unavailable ] || exit 93
                case "${ODYSSEUS_TEST_GH_MODE:-}" in
                    cq-malformed) printf '{"enabled":true}\n{"enabled":' ;;
                    cq-multiple) printf '%s\n' '{"enabled":true}' '{"enabled":false}' ;;
                    *) printf '%s\n' '{"enabled":false}' ;;
                esac
                ;;
            repos/HomericIntelligence/*/contents/*)
                [ "${ODYSSEUS_TEST_GH_MODE:-}" != unavailable ] || exit 93
                printf '%s\n' '{}'
                ;;
            repos/HomericIntelligence/*)
                [ "${ODYSSEUS_TEST_GH_MODE:-}" != unavailable ] || exit 93
                case "$*" in
                    *dependabot_security_updates*) printf '%s\n' true ;;
                    *secret_scanning_push_protection*) printf '%s\n' true ;;
                    *secret_scanning*) printf '%s\n' false ;;
                    *) exit 94 ;;
                esac
                ;;
            *)
                exit 95
                ;;
        esac
        ;;
    *)
        exit 96
        ;;
esac
EOF
chmod +x "$fixture_bin/gh"

info "failed remote readback remains unavailable under Bash $PROBE_BASH_VERSION"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=unavailable \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   > "$fixture_root/unavailable.out" 2>&1 \
   && grep -Fq '| Odysseus | unavailable | unavailable | unavailable | unavailable | unavailable | unavailable |' \
        "$fixture_root/unavailable.out"; then
    pass "Bash $PROBE_BASH_VERSION does not convert unavailable state"
else
    fail "failed GitHub readback produced a concrete setting"
fi

info "explicit boolean readback preserves enabled and disabled states"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   > "$fixture_root/readback.out" 2>&1 \
   && grep -Fq '| Odysseus | enabled | disabled | enabled | configured | disabled | present |' \
        "$fixture_root/readback.out"; then
    pass "explicit GitHub states round-trip through the report"
else
    fail "explicit GitHub states were rewritten or lost"
fi

if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=cs-not-configured \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   > "$fixture_root/not-configured.out" 2>&1 \
   && grep -Fq '| Odysseus | enabled | disabled | enabled | not-configured | disabled | present |' \
        "$fixture_root/not-configured.out"; then
    pass "documented not-configured Code Scanning state is preserved"
else
    fail "documented not-configured Code Scanning state was lost"
fi

info "Code Scanning accepts only documented states"
for hostile_state in cs-unknown cs-control cs-newline cs-pipe; do
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE="$hostile_state" \
       ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
       > "$fixture_root/$hostile_state.out" 2>&1 \
       && grep -Fq '| Odysseus | enabled | disabled | enabled | unavailable | disabled | present |' \
            "$fixture_root/$hostile_state.out" \
       && ! grep -Eq 'malicious-row|malicious-cell' \
            "$fixture_root/$hostile_state.out" \
       && ! grep -Fq '| unknown |' "$fixture_root/$hostile_state.out" \
       && ! grep -Fq "$escape_character" \
            "$fixture_root/$hostile_state.out"; then
        pass "$hostile_state is unavailable rather than report content"
    else
        fail "$hostile_state escaped the documented Code Scanning state grammar"
    fi
done

info "canonical gitlink URLs contain exactly one repository segment"
for hostile_url in nested prefix suffix scheme host org pipe; do
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GIT_URL_MODE="$hostile_url" \
       ODYSSEUS_TEST_GH_MODE=readback ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
       > "$fixture_root/url-$hostile_url.out" 2>&1; then
        fail "$hostile_url canonical URL produced a report"
    elif grep -Fq 'unsupported canonical gitlink URL' \
            "$fixture_root/url-$hostile_url.out"; then
        pass "$hostile_url canonical URL is rejected before remote readback"
    else
        fail "$hostile_url canonical URL omitted its trust-boundary error"
    fi
done

info "canonical gitlink sections are complete and one-to-one"
for malformed_inventory in duplicate-name duplicate-path duplicate-url-entry \
                           orphan-url missing-url duplicate-repo-url \
                           dot-name dot-path leading-dot-name terminal-dot-name \
                           trailing-slash-name leading-dot-path terminal-dot-path \
                           trailing-slash-path; do
    : > "$gh_log"
    case "$malformed_inventory" in
        duplicate-name) expected_error='duplicate canonical gitlink name' ;;
        duplicate-path) expected_error='duplicate canonical gitlink path' ;;
        duplicate-url-entry) expected_error='duplicate canonical gitlink URL name' ;;
        orphan-url) expected_error='canonical gitlink URL missing for control.Nestor' ;;
        missing-url) expected_error='canonical gitlink path and URL inventories differ' ;;
        duplicate-repo-url) expected_error='duplicate canonical gitlink URL:' ;;
        dot-name|leading-dot-name|terminal-dot-name|trailing-slash-name)
            expected_error='unsafe canonical gitlink name'
            ;;
        dot-path|leading-dot-path|terminal-dot-path|trailing-slash-path)
            expected_error='unsafe canonical gitlink path'
            ;;
        *) expected_error='' ;;
    esac
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" \
       ODYSSEUS_TEST_GIT_INVENTORY_MODE="$malformed_inventory" \
       ODYSSEUS_TEST_GH_MODE=readback ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
       > "$fixture_root/inventory-$malformed_inventory.out" 2>&1; then
        fail "$malformed_inventory canonical inventory produced a report"
    elif [ -s "$gh_log" ]; then
        fail "$malformed_inventory canonical inventory reached GitHub"
    elif [ -n "$expected_error" ] \
        && ! grep -Fq "$expected_error" \
            "$fixture_root/inventory-$malformed_inventory.out"; then
        fail "$malformed_inventory was rejected by the wrong inventory guard"
    else
        pass "$malformed_inventory canonical inventory stops before GitHub"
    fi
done

info "failed canonical inventory producers cannot publish partial scope"
for unavailable_inventory in unavailable-inventory partial-inventory \
                             partial-url-inventory; do
    : > "$gh_log"
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" \
       ODYSSEUS_TEST_GIT_INVENTORY_MODE="$unavailable_inventory" \
       ODYSSEUS_TEST_GH_MODE=readback ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
       > "$fixture_root/inventory-$unavailable_inventory.out" 2>&1; then
        fail "$unavailable_inventory produced a partial repository report"
    elif [ -s "$gh_log" ]; then
        fail "$unavailable_inventory reached GitHub with partial scope"
    elif grep -Fq 'could not read the canonical gitlink inventory' \
            "$fixture_root/inventory-$unavailable_inventory.out"; then
        pass "$unavailable_inventory remains unavailable before GitHub"
    else
        fail "$unavailable_inventory omitted its inventory failure"
    fi
done

info "canonical path and URL rows come from one Git snapshot"
: > "$git_log"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   > "$fixture_root/one-git-snapshot.out" 2>&1 \
   && [ "$(grep -Ec '^config( |$)' "$git_log")" -eq 1 ]; then
    pass "one git-config read binds every canonical path and URL"
else
    fail "canonical paths and URLs came from separate git-config snapshots"
fi

info "Code Quality accepts exactly one parsed state"
for malformed_quality in cq-malformed cq-multiple; do
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE="$malformed_quality" \
       ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
       > "$fixture_root/$malformed_quality.out" 2>&1 \
       && grep -Fq '| Odysseus | enabled | disabled | enabled | configured | unavailable | present |' \
            "$fixture_root/$malformed_quality.out" \
       && ! grep -Eq '\| (enabled|disabled)$' \
            "$fixture_root/$malformed_quality.out"; then
        pass "$malformed_quality Code Quality response remains unavailable"
    else
        fail "$malformed_quality Code Quality response escaped as report data"
    fi
done

info "organization inventory has no fixed repository count or member"
: > "$gh_log"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" --all \
   > "$fixture_root/all.out" 2>&1 \
   && grep -Fq 'mode: organization inventory' "$fixture_root/all.out" \
   && ! grep -Eq 'all 17|modular-community' "$fixture_root/all.out" \
   && grep -Fq 'api --paginate orgs/HomericIntelligence/repos?per_page=100&type=all --jq .[].name' \
        "$gh_log" \
   && ! grep -q '^repo list ' "$gh_log"; then
    pass "organization scope comes from a complete paginated live inventory"
else
    fail "organization scope is fixed or silently limited to one page"
fi

info "unavailable organization inventory cannot become an empty report"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=inventory-unavailable \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" --all \
   > "$fixture_root/inventory-unavailable.out" 2>&1; then
    fail "failed organization discovery produced a report"
elif grep -Fq 'could not read the organization repository inventory' \
        "$fixture_root/inventory-unavailable.out"; then
    pass "failed organization discovery remains unavailable"
else
    fail "failed organization discovery omitted its unavailable boundary"
fi

info "organization repository identities are validated and unique"
for unsafe_mode in unsafe-inventory duplicate-inventory; do
    if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE="$unsafe_mode" \
       ODYSSEUS_TEST_GH_LOG="$gh_log" \
       PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" --all \
       > "$fixture_root/$unsafe_mode.out" 2>&1; then
        fail "$unsafe_mode produced a report"
    elif grep -Eq 'unsafe repository name|duplicate repository' \
            "$fixture_root/$unsafe_mode.out"; then
        pass "$unsafe_mode stops before per-repository readback"
    else
        fail "$unsafe_mode omitted its inventory error"
    fi
done

info "output publication is atomic and does not follow symlinks"
printf '%s\n' preserve-me > "$fixture_root/victim"
ln -s "$fixture_root/victim" "$fixture_root/report.md"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   --output "$fixture_root/report.md" > "$fixture_root/symlink.out" 2>&1; then
    fail "probe followed a symlinked output target"
elif [ "$(cat "$fixture_root/victim")" = preserve-me ]; then
    pass "symlinked output is rejected without changing its referent"
else
    fail "symlinked output changed its referent"
fi
rm "$fixture_root/report.md"
if ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   --output "$fixture_root/report.md" > "$fixture_root/safe-output.out" 2>&1 \
   && [ -s "$fixture_root/report.md" ] \
   && cmp -s "$fixture_root/report.md" "$fixture_root/safe-output.out"; then
    pass "safe output publication contains the complete emitted report"
else
    fail "safe output publication was partial or divergent"
fi

info "output publication rebinds its destination before exact rename"
mkdir "$fixture_root/output-victim"
if PYTHONPATH="$python_hooks" \
   ODYSSEUS_TEST_SWAP_LSTAT_TARGET="swap-report.md" \
   ODYSSEUS_TEST_SWAP_VICTIM="$fixture_root/output-victim" \
   ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   --output "$fixture_root/swap-report.md" \
   > "$fixture_root/swap-output.out" 2>&1; then
    fail "a swapped directory symlink accepted report publication"
elif [ -n "$(ls -A "$fixture_root/output-victim")" ]; then
    fail "report publication redirected a temporary file into a directory"
elif [ -L "$fixture_root/swap-report.md" ]; then
    pass "a post-lstat directory symlink cannot redirect report publication"
else
    fail "report publication did not rebind its destination"
fi
rm "$fixture_root/swap-report.md"

info "output publication remains inside its bound parent directory"
mkdir "$fixture_root/publication-parent" "$fixture_root/publication-victim"
if PYTHONPATH="$python_hooks" \
   ODYSSEUS_TEST_SWAP_PARENT_TARGET="$fixture_root/publication-parent" \
   ODYSSEUS_TEST_SWAP_PARENT_ORIGINAL="$fixture_root/publication-original" \
   ODYSSEUS_TEST_SWAP_PARENT_VICTIM="$fixture_root/publication-victim" \
   ODYSSEUS_TEST_REPO_ROOT="$ROOT" ODYSSEUS_TEST_GH_MODE=readback \
   ODYSSEUS_TEST_GH_LOG="$gh_log" \
   PATH="$fixture_bin" "$PROBE_SHELL" "$ROOT/tools/probe-code-quality.sh" \
   --output "$fixture_root/publication-parent/report.md" \
   > "$fixture_root/parent-swap.out" 2>&1; then
    fail "a swapped report parent was accepted as the publication namespace"
elif [ -n "$(ls -A "$fixture_root/publication-victim")" ]; then
    fail "a swapped report parent redirected publication outside the bound directory"
elif ! grep -Fq '# HomericIntelligence — repository security readbacks' \
        "$fixture_root/publication-original/report.md"; then
    fail "the descriptor-relative rename did not stay in its bound directory"
else
    pass "a replace-boundary ancestor swap stays in the bound directory and fails closed"
fi

summary
exit_code
