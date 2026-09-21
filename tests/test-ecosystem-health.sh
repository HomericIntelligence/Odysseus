#!/usr/bin/env bash
# Behavior tests for the ecosystem health reporter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
REPORTER_SHELL="${ODYSSEUS_TEST_SHELL:-$BASH}"
[ -x "$REPORTER_SHELL" ] || {
    echo "ERROR: selected reporter shell is not executable: $REPORTER_SHELL" >&2
    exit 1
}
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

if ! fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-ecosystem-health.XXXXXX")" \
    || [ -z "$fixture_root" ] || [ ! -d "$fixture_root" ]; then
    echo "ERROR: could not create ecosystem-health fixture" >&2
    exit 1
fi
fixture_repo="$fixture_root/repo"
fixture_bin="$fixture_root/bin"
gh_log="$fixture_root/gh.log"
mkdir -p "$fixture_repo" "$fixture_bin"

cleanup_fixture() {
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove ecosystem-health fixture: $fixture_root" >&2
    fi
}
trap cleanup_fixture EXIT

git -C "$fixture_repo" init -q
cat > "$fixture_repo/.gitmodules" <<'EOF'
[submodule "control/Atlas"]
    path = control/Atlas
    url = https://github.com/HomericIntelligence/Atlas.git
EOF

cat > "$fixture_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${ODYSSEUS_TEST_GH_LOG:?}"

trigger_sink_race() {
    [ -n "${ODYSSEUS_TEST_SINK_RACE:-}" ] || return 0
    [ ! -e "${ODYSSEUS_TEST_RACE_FLAG:?}" ] || return 0
    : > "$ODYSSEUS_TEST_RACE_FLAG"
    case "$ODYSSEUS_TEST_SINK_RACE" in
        target)
            mv -- "${ODYSSEUS_TEST_RACE_TARGET:?}" \
                "${ODYSSEUS_TEST_RACE_ORIGINAL:?}"
            mv -- "${ODYSSEUS_TEST_RACE_VICTIM:?}" \
                "$ODYSSEUS_TEST_RACE_TARGET"
            ;;
        ancestor)
            mv -- "${ODYSSEUS_TEST_RACE_PARENT:?}" \
                "${ODYSSEUS_TEST_RACE_PARENT_ORIGINAL:?}"
            mv -- "${ODYSSEUS_TEST_RACE_PARENT_VICTIM:?}" \
                "$ODYSSEUS_TEST_RACE_PARENT"
            ;;
        *) exit 94 ;;
    esac
}

has_arg() {
    local expected="$1"
    shift
    local arg
    for arg in "$@"; do
        [ "$arg" = "$expected" ] && return 0
    done
    return 1
}

case "${1:-}" in
    repo)
        [ "${2:-}" = view ] || exit 90
        trigger_sink_race
        if [ "${ODYSSEUS_TEST_GH_MODE:-ok}" = branch-unavailable ]; then
            exit 71
        fi
        if [ "${ODYSSEUS_TEST_GH_MODE:-ok}" = hostile-markdown ]; then
            printf '%s\n' '{"defaultBranchRef":{"name":"trunk|[branch]\\display"}}'
        elif has_arg --jq "$@"; then
            printf '%s\n' trunk
        else
            printf '%s\n' '{"defaultBranchRef":{"name":"trunk"}}'
        fi
        ;;
    api)
        endpoint=""
        for arg in "$@"; do
            case "$arg" in
                repos/*) endpoint="$arg"; break ;;
            esac
        done
        [ -n "$endpoint" ] || exit 91
        case "$endpoint" in
            repos/*/git/trees/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\?recursive=1)
                [ "${ODYSSEUS_TEST_GH_MODE:-ok}" != tree-unavailable ] || exit 72
                if [ "${ODYSSEUS_TEST_GH_MODE:-ok}" = tree-truncated ]; then
                    printf '%s\n' \
                        '{"truncated":true,"tree":[{"path":"README.md","type":"blob"}]}'
                else
                    printf '%s\n' \
                        '{"truncated":false,"tree":[{"path":"LICENSE","type":"blob"},{"path":"CLAUDE.md","type":"blob"},{"path":"README.md","type":"blob"}]}'
                fi
                ;;
            repos/*/actions/runs\?*)
                [ "${ODYSSEUS_TEST_GH_MODE:-ok}" != ci-unavailable ] || exit 73
                if has_arg --jq "$@"; then
                    case "${ODYSSEUS_TEST_GH_MODE:-ok}" in
                        no-ci) printf '%s\n' none ;;
                        pending-ci) printf '%s\n' null ;;
                        *) printf '%s\n' success ;;
                    esac
                else
                    case "${ODYSSEUS_TEST_GH_MODE:-ok}" in
                        no-ci) printf '%s\n' '{"total_count":0,"workflow_runs":[]}' ;;
                        pending-ci) printf '%s\n' '{"total_count":1,"workflow_runs":[{"status":"in_progress","conclusion":null}]}' ;;
                        hostile-markdown)
                            printf '%s\n' '{"total_count":1,"workflow_runs":[{"status":"completed","conclusion":"result|[ci]\\display"}]}'
                            ;;
                        *) printf '%s\n' '{"total_count":1,"workflow_runs":[{"status":"completed","conclusion":"success"}]}' ;;
                    esac
                fi
                ;;
            repos/*/contents/*)
                # Compatibility with the pre-repair implementation. Missing
                # justfile and pixi.toml are ordinary 404-like absences.
                case "$endpoint" in
                    */justfile|*/pixi.toml) exit 1 ;;
                    *)
                        [ "${ODYSSEUS_TEST_GH_MODE:-ok}" != tree-unavailable ] || exit 72
                        printf '%s\n' '{}'
                        ;;
                esac
                ;;
            repos/*/commits/trunk|repos/*/commits/trunk%7C%5Bbranch%5D%5Cdisplay|repos/*/commits/\?)
                [ "${ODYSSEUS_TEST_GH_MODE:-ok}" != commit-unavailable ] || exit 74
                if has_arg --jq "$@"; then
                    printf '%s\n' 2026-09-14T00:00:00Z
                else
                    printf '%s\n' \
                        '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit":{"committer":{"date":"2026-09-14T00:00:00Z"}}}'
                fi
                ;;
            *) exit 92 ;;
        esac
        ;;
    *) exit 93 ;;
esac
EOF
chmod +x "$fixture_bin/gh"

cat > "$fixture_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

candidate=""
for candidate in "$@"; do :; done
if [ -n "${ODYSSEUS_TEST_CLEANUP_RACE_VICTIM:-}" ] \
    && [ -n "$candidate" ] \
    && [ ! -e "${ODYSSEUS_TEST_CLEANUP_RACE_LOG:?}" ]; then
    /bin/mv -- "$candidate" "${ODYSSEUS_TEST_CLEANUP_RACE_ORIGINAL:?}"
    /bin/mv -- "$ODYSSEUS_TEST_CLEANUP_RACE_VICTIM" "$candidate"
    printf '%s\n' "$candidate" > "$ODYSSEUS_TEST_CLEANUP_RACE_LOG"
fi
exec /bin/rm "$@"
EOF
chmod +x "$fixture_bin/rm"

run_reporter() {
    local mode="$1"
    shift
    : > "$gh_log"
    set +e
    (
        cd "$fixture_repo" || exit 99
        unset BASH_ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP
        ODYSSEUS_TEST_GH_LOG="$gh_log" \
        ODYSSEUS_TEST_GH_MODE="$mode" \
        ODYSSEUS_TEST_SINK_RACE="${ODYSSEUS_TEST_SINK_RACE:-}" \
        ODYSSEUS_TEST_RACE_FLAG="${ODYSSEUS_TEST_RACE_FLAG:-}" \
        ODYSSEUS_TEST_RACE_TARGET="${ODYSSEUS_TEST_RACE_TARGET:-}" \
        ODYSSEUS_TEST_RACE_ORIGINAL="${ODYSSEUS_TEST_RACE_ORIGINAL:-}" \
        ODYSSEUS_TEST_RACE_VICTIM="${ODYSSEUS_TEST_RACE_VICTIM:-}" \
        ODYSSEUS_TEST_RACE_PARENT="${ODYSSEUS_TEST_RACE_PARENT:-}" \
        ODYSSEUS_TEST_RACE_PARENT_ORIGINAL="${ODYSSEUS_TEST_RACE_PARENT_ORIGINAL:-}" \
        ODYSSEUS_TEST_RACE_PARENT_VICTIM="${ODYSSEUS_TEST_RACE_PARENT_VICTIM:-}" \
        GITHUB_STEP_SUMMARY="${ODYSSEUS_TEST_GITHUB_SUMMARY:-}" \
        PATH="$fixture_bin:$PATH" \
            "$REPORTER_SHELL" "$ROOT/scripts/ecosystem-health.sh" "$@"
    ) > "$fixture_root/stdout" 2> "$fixture_root/stderr"
    reporter_status=$?
    set -e
}

run_summary_reporter() {
    local mode="$1" summary_path="$2"
    : > "$gh_log"
    set +e
    (
        cd "$fixture_repo" || exit 99
        unset BASH_ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP
        ODYSSEUS_TEST_GH_LOG="$gh_log" \
        ODYSSEUS_TEST_GH_MODE="$mode" \
        GITHUB_STEP_SUMMARY="$summary_path" \
        PATH="$fixture_bin:$PATH" \
            "$REPORTER_SHELL" "$ROOT/scripts/ecosystem-health.sh" --github-summary
    ) > "$fixture_root/summary-stdout" 2> "$fixture_root/summary-stderr"
    summary_status=$?
    set -e
}

file_inode() {
    env -u PYTHONPATH python3 -I -S - "$1" <<'PY'
import os
import sys
print(os.lstat(sys.argv[1]).st_ino)
PY
}

file_mode() {
    env -u PYTHONPATH python3 -I -S - "$1" <<'PY'
import os
import stat
import sys
print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))
PY
}

info "verified file absence and no workflow runs are reportable states"
run_reporter no-ci
if [ "$reporter_status" -eq 0 ] \
    && grep -Fq '| HomericIntelligence/Atlas | trunk | ✅ | ✅ | ❌ | ❌ | ✅ | ⚠️ none | 2026-09-14 |' \
        "$fixture_root/stdout"; then
    pass "absence remains distinct from an unavailable GitHub read"
else
    fail "valid absent files or empty CI history were misreported"
fi

info "an in-progress latest run is not reported as unavailable"
run_reporter pending-ci
if [ "$reporter_status" -eq 0 ] \
    && grep -Fq '⚠️ pending' "$fixture_root/stdout"; then
    pass "a valid pending CI state is preserved"
else
    fail "pending CI was not represented as a valid live state"
fi

info "untrusted branch and CI values cannot inject Markdown table syntax"
run_reporter hostile-markdown
if [ "$reporter_status" -eq 0 ] \
    && grep -Fq 'trunk\|\[branch\]\\display' "$fixture_root/stdout" \
    && grep -Fq 'result\|\[ci\]\\display' "$fixture_root/stdout" \
    && ! grep -Fq 'trunk|[branch]\display' "$fixture_root/stdout" \
    && ! grep -Fq 'result|[ci]\display' "$fixture_root/stdout"; then
    pass "external table values are Markdown escaped"
else
    fail "external branch or CI data changed the Markdown table structure"
fi

info "unavailable repository data cannot publish stdout or output files"
output_path="$fixture_root/health.md"
printf '%s\n' 'original health' > "$output_path"
run_reporter tree-unavailable --output "$output_path"
if [ "$reporter_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original health' ]; then
    pass "unavailable tree data stops before publication"
else
    fail "unavailable tree data became missing-file results"
fi

info "a truncated Git tree is incomplete rather than authoritative absence"
printf '%s\n' 'original health' > "$output_path"
run_reporter tree-truncated --output "$output_path"
if [ "$reporter_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original health' ]; then
    pass "truncated repository inventory fails closed"
else
    fail "truncated tree data was rendered as file absence"
fi

info "unavailable CI data cannot become a warning in a completed report"
run_reporter ci-unavailable
if [ "$reporter_status" -ne 0 ] && [ ! -s "$fixture_root/stdout" ]; then
    pass "failed CI readback is unavailable"
else
    fail "failed CI readback was converted to a report row"
fi

info "malformed submodule inventory fails before publication"
cp "$fixture_repo/.gitmodules" "$fixture_root/gitmodules.valid"
printf '%s\n' '[submodule "broken"' > "$fixture_repo/.gitmodules"
printf '%s\n' 'original health' > "$output_path"
run_reporter ok --output "$output_path"
mv "$fixture_root/gitmodules.valid" "$fixture_repo/.gitmodules"
if [ "$reporter_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original health' ]; then
    pass "invalid canonical inventory is unavailable"
else
    fail "invalid inventory produced a partial health report"
fi

info "output and GitHub summary sinks reject symlinks"
external_output="$fixture_root/external-output.md"
external_summary="$fixture_root/external-summary.md"
printf '%s\n' 'output sentinel' > "$external_output"
printf '%s\n' 'summary sentinel' > "$external_summary"
ln -s "$external_output" "$fixture_root/output-link.md"
ln -s "$external_summary" "$fixture_root/summary-link.md"
run_reporter ok --output "$fixture_root/output-link.md"
output_link_status=$reporter_status
run_summary_reporter ok "$fixture_root/summary-link.md"
summary_link_status=$summary_status
if [ "$output_link_status" -ne 0 ] \
    && [ "$summary_link_status" -ne 0 ] \
    && [ "$(cat "$external_output")" = 'output sentinel' ] \
    && [ "$(cat "$external_summary")" = 'summary sentinel' ]; then
    pass "report sinks do not follow symbolic links"
else
    fail "a report sink followed or accepted a symbolic link"
fi

info "output and GitHub summary cannot name the same report entry"
same_sink="$fixture_root/same-health-sink.md"
printf '%s\n' 'same health sink sentinel' > "$same_sink"
ODYSSEUS_TEST_GITHUB_SUMMARY="$same_sink" \
    run_reporter ok --output "$same_sink" --github-summary
if [ "$reporter_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$same_sink")" = 'same health sink sentinel' ] \
    && [ ! -s "$gh_log" ]; then
    pass "same report sinks are rejected before any read or publication"
else
    fail "the report accepted identical output and summary sinks"
fi

info "replace and append preserve direct sink behavior and file modes"
direct_output="$fixture_root/direct-output.md"
direct_summary="$fixture_root/direct-summary.md"
printf '%s\n' 'replace sentinel' > "$direct_output"
printf '%s\n' 'append sentinel' > "$direct_summary"
chmod 0600 "$direct_output" "$direct_summary"
run_reporter ok --output "$direct_output"
direct_output_status=$reporter_status
run_summary_reporter ok "$direct_summary"
if [ "$direct_output_status" -eq 0 ] \
    && [ "$summary_status" -eq 0 ] \
    && grep -Fq '# Ecosystem Health Status' "$direct_output" \
    && ! grep -Fq 'replace sentinel' "$direct_output" \
    && grep -Fq 'append sentinel' "$direct_summary" \
    && grep -Fq '# Ecosystem Health Status' "$direct_summary" \
    && [ "$(file_mode "$direct_output")" = 0o600 ] \
    && [ "$(file_mode "$direct_summary")" = 0o600 ]; then
    pass "replace and append publish exact content without widening modes"
else
    fail "direct replace or append semantics changed"
fi

info "multiply linked output and summary sinks are rejected"
hardlink_output_victim="$fixture_root/hardlink-output-victim.md"
hardlink_summary_victim="$fixture_root/hardlink-summary-victim.md"
printf '%s\n' 'hardlink output sentinel' > "$hardlink_output_victim"
printf '%s\n' 'hardlink summary sentinel' > "$hardlink_summary_victim"
cp "$hardlink_output_victim" "$fixture_root/hardlink-output.before"
cp "$hardlink_summary_victim" "$fixture_root/hardlink-summary.before"
output_victim_inode="$(file_inode "$hardlink_output_victim")"
summary_victim_inode="$(file_inode "$hardlink_summary_victim")"
ln "$hardlink_output_victim" "$fixture_root/hardlink-output.md"
ln "$hardlink_summary_victim" "$fixture_root/hardlink-summary.md"
run_reporter ok --output "$fixture_root/hardlink-output.md"
hardlink_output_status=$reporter_status
run_summary_reporter ok "$fixture_root/hardlink-summary.md"
if [ "$hardlink_output_status" -ne 0 ] \
    && [ "$summary_status" -ne 0 ] \
    && [ "$fixture_root/hardlink-output.md" -ef "$hardlink_output_victim" ] \
    && [ "$fixture_root/hardlink-summary.md" -ef "$hardlink_summary_victim" ] \
    && [ "$(file_inode "$hardlink_output_victim")" = "$output_victim_inode" ] \
    && [ "$(file_inode "$hardlink_summary_victim")" = "$summary_victim_inode" ] \
    && cmp -s "$hardlink_output_victim" "$fixture_root/hardlink-output.before" \
    && cmp -s "$hardlink_summary_victim" "$fixture_root/hardlink-summary.before"; then
    pass "hardlinked report sinks cannot redirect or receive publication"
else
    fail "a multiply linked report sink was accepted or changed"
fi

info "a target replacement after initial binding stops publication"
race_target="$fixture_root/raced-output.md"
race_original="$fixture_root/raced-output.original"
race_victim="$fixture_root/raced-output.victim"
race_flag="$fixture_root/raced-output.flag"
printf '%s\n' 'original target sentinel' > "$race_target"
printf '%s\n' 'replacement victim sentinel' > "$race_victim"
cp "$race_victim" "$fixture_root/raced-output-victim.before"
race_victim_inode="$(file_inode "$race_victim")"
ODYSSEUS_TEST_SINK_RACE=target \
ODYSSEUS_TEST_RACE_FLAG="$race_flag" \
ODYSSEUS_TEST_RACE_TARGET="$race_target" \
ODYSSEUS_TEST_RACE_ORIGINAL="$race_original" \
ODYSSEUS_TEST_RACE_VICTIM="$race_victim" \
    run_reporter ok --output "$race_target"
if [ "$reporter_status" -ne 0 ] \
    && [ "$(cat "$race_original")" = 'original target sentinel' ] \
    && [ ! -e "$race_victim" ] \
    && [ "$(file_inode "$race_target")" = "$race_victim_inode" ] \
    && cmp -s "$race_target" "$fixture_root/raced-output-victim.before"; then
    pass "a same-UID target swap leaves both bound files unchanged"
else
    fail "a post-binding target replacement received report output"
fi
unset ODYSSEUS_TEST_SINK_RACE ODYSSEUS_TEST_RACE_FLAG \
    ODYSSEUS_TEST_RACE_TARGET ODYSSEUS_TEST_RACE_ORIGINAL \
    ODYSSEUS_TEST_RACE_VICTIM

info "an ancestor swap cannot redirect report publication"
race_parent="$fixture_root/raced-parent"
race_parent_original="$fixture_root/raced-parent.original"
race_parent_victim="$fixture_root/raced-parent.victim"
race_parent_flag="$fixture_root/raced-parent.flag"
mkdir "$race_parent" "$race_parent_victim"
printf '%s\n' 'original parent target' > "$race_parent/health.md"
printf '%s\n' 'ancestor victim sentinel' > "$race_parent_victim/health.md"
cp "$race_parent_victim/health.md" "$fixture_root/ancestor-victim.before"
ancestor_victim_inode="$(file_inode "$race_parent_victim/health.md")"
ODYSSEUS_TEST_SINK_RACE=ancestor \
ODYSSEUS_TEST_RACE_FLAG="$race_parent_flag" \
ODYSSEUS_TEST_RACE_PARENT="$race_parent" \
ODYSSEUS_TEST_RACE_PARENT_ORIGINAL="$race_parent_original" \
ODYSSEUS_TEST_RACE_PARENT_VICTIM="$race_parent_victim" \
    run_reporter ok --output "$race_parent/health.md"
if [ "$reporter_status" -ne 0 ] \
    && [ ! -e "$race_parent_victim" ] \
    && [ "$(file_inode "$race_parent/health.md")" = "$ancestor_victim_inode" ] \
    && cmp -s "$race_parent/health.md" "$fixture_root/ancestor-victim.before"; then
    pass "a swapped parent path cannot redirect the report"
else
    fail "ancestor replacement redirected report publication"
fi
unset ODYSSEUS_TEST_SINK_RACE ODYSSEUS_TEST_RACE_FLAG \
    ODYSSEUS_TEST_RACE_PARENT ODYSSEUS_TEST_RACE_PARENT_ORIGINAL \
    ODYSSEUS_TEST_RACE_PARENT_VICTIM

info "publication requires an owner-private direct parent"
public_parent="$fixture_root/public-parent"
mkdir "$public_parent"
chmod 0777 "$public_parent"
run_reporter ok --output "$public_parent/health.md"
chmod 0700 "$public_parent"
if [ "$reporter_status" -ne 0 ] && [ ! -e "$public_parent/health.md" ]; then
    pass "a group/world-writable parent is rejected before creation"
else
    fail "report publication accepted a non-private parent"
fi

info "report collection does not create a pathname-cleanup boundary"
cleanup_race_victim="$fixture_root/cleanup-race.victim"
cleanup_race_original="$fixture_root/cleanup-race.original"
cleanup_race_log="$fixture_root/cleanup-race.log"
runtime_tmp="$fixture_root/runtime-tmp"
mkdir "$cleanup_race_victim"
mkdir "$runtime_tmp"
printf '%s\n' 'cleanup victim sentinel' > "$cleanup_race_victim/sentinel"
export ODYSSEUS_TEST_CLEANUP_RACE_VICTIM="$cleanup_race_victim"
export ODYSSEUS_TEST_CLEANUP_RACE_ORIGINAL="$cleanup_race_original"
export ODYSSEUS_TEST_CLEANUP_RACE_LOG="$cleanup_race_log"
TMPDIR="$runtime_tmp" run_reporter ok
unset ODYSSEUS_TEST_CLEANUP_RACE_VICTIM \
    ODYSSEUS_TEST_CLEANUP_RACE_ORIGINAL ODYSSEUS_TEST_CLEANUP_RACE_LOG
if [ "$reporter_status" -eq 0 ] \
    && [ "$(cat "$cleanup_race_victim/sentinel" 2>/dev/null)" = \
        'cleanup victim sentinel' ] \
    && [ ! -e "$cleanup_race_log" ] \
    && [ -z "$(find "$runtime_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    pass "report collection needs no temporary pathname or recursive cleanup"
else
    fail "report collection created a mutable temporary cleanup boundary"
fi

summary
exit_code
