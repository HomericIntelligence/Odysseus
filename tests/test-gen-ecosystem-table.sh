#!/usr/bin/env bash
# Behavior tests for the ecosystem CI table generator.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
GENERATOR_SHELL="${ODYSSEUS_TEST_SHELL:-$BASH}"
[ -x "$GENERATOR_SHELL" ] || {
    echo "ERROR: selected generator shell is not executable: $GENERATOR_SHELL" >&2
    exit 1
}
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

if ! fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-ecosystem-table.XXXXXX")" \
    || [ -z "$fixture_root" ] || [ ! -d "$fixture_root" ]; then
    echo "ERROR: could not create ecosystem-table fixture" >&2
    exit 1
fi
fixture_root="$(cd "$fixture_root" && pwd -P)"
fixture_repo="$fixture_root/repo"
fixture_bin="$fixture_root/bin"
gh_log="$fixture_root/gh.log"
python_hooks="$fixture_root/python-hooks"
mkdir -p "$fixture_repo" "$fixture_bin" "$python_hooks"

cleanup_fixture() {
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove ecosystem-table fixture: $fixture_root" >&2
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
        repo="${3:-}"
        if [ "${ODYSSEUS_TEST_GH_MODE:-ok}" = branch-unavailable ] \
            && [ "$repo" = HomericIntelligence/Atlas ]; then
            printf '%s\n' 'simulated branch read failure' >&2
            exit 71
        fi
        if has_arg --jq "$@"; then
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
            repos/*/commits/trunk|repos/*/commits/main)
                if has_arg --jq "$@"; then
                    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                else
                    printf '%s\n' \
                        '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit":{"committer":{"date":"2026-09-14T00:00:00Z"}}}'
                fi
                ;;
            repos/*/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs\?*)
                case "${ODYSSEUS_TEST_GH_MODE:-ok}" in
                    checks-unavailable)
                        printf '%s\n' 'simulated check read failure' >&2
                        exit 72
                        ;;
                    checks-incomplete)
                        if has_arg --slurp "$@"; then
                            printf '%s\n' \
                                '[{"total_count":2,"check_runs":[{"name":"build"}]}]'
                        else
                            printf '%s\n' build
                        fi
                        ;;
                    no-checks)
                        if has_arg --slurp "$@"; then
                            printf '%s\n' '[{"total_count":0,"check_runs":[]}]'
                        fi
                        ;;
                    paged)
                        if has_arg --slurp "$@"; then
                            printf '%s\n' \
                                '[{"total_count":2,"check_runs":[{"name":"build"}]},{"total_count":2,"check_runs":[{"name":"security/dependency-scan"}]}]'
                        else
                            printf '%s\n' build
                        fi
                        ;;
                    *)
                        if has_arg --slurp "$@"; then
                            printf '%s\n' \
                                '[{"total_count":2,"check_runs":[{"name":"build"},{"name":"custom-gate"}]}]'
                        else
                            printf '%s\n' build custom-gate
                        fi
                        ;;
                esac
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

# Ambient startup probe. The trusted publisher must not import this module.
cat > "$python_hooks/sitecustomize.py" <<'PY'
import os
import sys


real_open = os.open
marker = os.environ.get("ODYSSEUS_TEST_SITECUSTOMIZE_MARKER", "")
if marker and any(value in {"append", "inject", "replace"} for value in sys.argv):
    descriptor = real_open(marker, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, b"ambient sitecustomize loaded\n")
    finally:
        os.close(descriptor)
PY

# Directly interpose the dangerous syscalls at their effect boundary. This
# remains deterministic even though the production entry point ignores ambient
# Python startup files.
publisher_probe="$fixture_root/publisher-probe.py"
cat > "$publisher_probe" <<'PY'
import importlib.util
import os
import signal
import stat
import sys

publisher_path, mode, target, original, victim, log = sys.argv[1:]
spec = importlib.util.spec_from_file_location("safe_report_publish_probe", publisher_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_replace = os.replace
real_unlink = os.unlink
real_write = os.write
real_open = os.open
real_fsync = os.fsync

binding = module.bind(target, "replace")

if mode == "replace-syscall":
    def hooked_replace(source, destination, *, src_dir_fd=None, dst_dir_fd=None):
        real_replace(target, original)
        real_replace(victim, target)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write("replace called")
        if src_dir_fd is None and dst_dir_fd is None:
            return real_replace(source, destination)
        return real_replace(
            source,
            destination,
            src_dir_fd=src_dir_fd,
            dst_dir_fd=dst_dir_fd,
        )

    module.os.replace = hooked_replace
    module.publish(target, "replace", binding, b"safe replacement\n")
elif mode == "unlink-syscall":
    writes = 0

    def failing_write(descriptor, content):
        global writes
        writes += 1
        if writes == 1:
            real_write(descriptor, bytes(content[:4]))
            raise OSError("test-forced partial write")
        return real_write(descriptor, content)

    def hooked_unlink(path, *, dir_fd=None):
        candidate = os.fsdecode(path)
        if not os.path.isabs(candidate):
            candidate = os.path.join(os.path.dirname(target), candidate)
        real_replace(candidate, original)
        real_replace(victim, candidate)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write(candidate)
        if dir_fd is None:
            return real_unlink(path)
        return real_unlink(path, dir_fd=dir_fd)

    module.os.write = failing_write
    module.os.unlink = hooked_unlink
    try:
        module.publish(target, "replace", binding, b"partial replacement\n")
    except OSError:
        raise SystemExit(42)
    raise SystemExit("forced write failure was not observed")
elif mode == "create-syscall":
    real_atomic_noreplace = getattr(module, "atomic_noreplace", None)
    if real_atomic_noreplace is None:
        raise SystemExit("atomic no-replace is unavailable")

    def hooked_atomic_noreplace(parent_descriptor, candidate_name, target_name):
        real_replace(victim, target)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write("exclusive commit reached")
        return real_atomic_noreplace(parent_descriptor, candidate_name, target_name)

    module.atomic_noreplace = hooked_atomic_noreplace
    try:
        module.publish(target, "replace", binding, b"safe replacement\n")
    except FileExistsError:
        raise SystemExit(43)
    raise SystemExit("exclusive creation race was not rejected")
elif mode == "existing-write-failure":
    writes = 0

    def failing_once_write(descriptor, content):
        global writes
        writes += 1
        if writes == 1:
            real_write(descriptor, bytes(content[:4]))
            raise OSError("test-forced existing-sink write failure")
        return real_write(descriptor, content)

    module.os.write = failing_once_write
    try:
        module.publish(target, "replace", binding, b"replacement that must fail\n")
    except OSError:
        raise SystemExit(44)
    raise SystemExit("forced existing-sink write failure was not observed")
elif mode == "existing-signal-interrupt":
    interrupted = False

    def signaling_write(descriptor, content):
        global interrupted
        if not interrupted:
            interrupted = True
            prefix = bytes(content[:4])
            written = real_write(descriptor, prefix)
            os.kill(os.getpid(), signal.SIGINT)
            return written
        return real_write(descriptor, content)

    module.os.write = signaling_write
    try:
        module.publish(
            target,
            "replace",
            binding,
            b"signal-safe complete replacement\n",
        )
    except KeyboardInterrupt:
        raise SystemExit(46)
    raise SystemExit("SIGINT did not interrupt after publication")
elif mode == "existing-final-exchange-race":
    real_atomic_exchange = getattr(module, "atomic_exchange", None)
    if real_atomic_exchange is None:
        raise SystemExit("atomic exchange is unavailable")
    raced = False

    def hooked_atomic_exchange(parent_descriptor, candidate_name, target_name):
        global raced
        if raced:
            return real_atomic_exchange(
                parent_descriptor,
                candidate_name,
                target_name,
            )
        raced = True
        real_replace(target, original)
        real_replace(victim, target)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write("exchange reached")
        return real_atomic_exchange(parent_descriptor, candidate_name, target_name)

    module.atomic_exchange = hooked_atomic_exchange
    try:
        module.publish(target, "replace", binding, b"safe replacement\n")
    except OSError:
        raise SystemExit(47)
    raise SystemExit("a foreign final-exchange victim was reported as success")
elif mode == "existing-candidate-exchange-race":
    real_atomic_exchange = getattr(module, "atomic_exchange", None)
    if real_atomic_exchange is None:
        raise SystemExit("atomic exchange is unavailable")
    raced = False

    def hooked_candidate_exchange(parent_descriptor, candidate_name, target_name):
        global raced
        if raced:
            return real_atomic_exchange(
                parent_descriptor,
                candidate_name,
                target_name,
            )
        raced = True
        candidate = os.path.join(os.path.dirname(target), candidate_name)
        real_replace(candidate, original)
        real_replace(victim, candidate)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write("candidate exchange reached")
        return real_atomic_exchange(parent_descriptor, candidate_name, target_name)

    module.atomic_exchange = hooked_candidate_exchange
    try:
        module.publish(target, "replace", binding, b"safe replacement\n")
    except OSError:
        raise SystemExit(48)
    raise SystemExit("a foreign exchange candidate was reported as success")
elif mode == "absent-candidate-noreplace-race":
    real_atomic_noreplace = getattr(module, "atomic_noreplace", None)
    if real_atomic_noreplace is None:
        raise SystemExit("atomic no-replace is unavailable")
    raced = False

    def hooked_candidate_noreplace(parent_descriptor, candidate_name, target_name):
        global raced
        if raced:
            return real_atomic_noreplace(
                parent_descriptor,
                candidate_name,
                target_name,
            )
        raced = True
        candidate = os.path.join(os.path.dirname(target), candidate_name)
        real_replace(candidate, original)
        real_replace(victim, candidate)
        with open(log, "w", encoding="utf-8") as destination_log:
            destination_log.write("candidate no-replace reached")
        return real_atomic_noreplace(parent_descriptor, candidate_name, target_name)

    module.atomic_noreplace = hooked_candidate_noreplace
    try:
        module.publish(target, "replace", binding, b"safe replacement\n")
    except OSError:
        raise SystemExit(49)
    raise SystemExit("a foreign no-replace candidate was reported as success")
elif mode in {"existing-parent-fsync-failure", "absent-parent-fsync-failure"}:
    parent_syncs = 0

    def failing_parent_fsync(descriptor):
        global parent_syncs
        if stat.S_ISDIR(os.fstat(descriptor).st_mode):
            parent_syncs += 1
            if parent_syncs == 2:
                raise OSError("test-forced final parent fsync failure")
        return real_fsync(descriptor)

    module.os.fsync = failing_parent_fsync
    try:
        module.publish(target, "replace", binding, b"fsync-safe replacement\n")
    except OSError:
        raise SystemExit(
            50 if mode == "existing-parent-fsync-failure" else 51
        )
    raise SystemExit("a final parent fsync failure was not propagated")
elif mode == "existing-sigkill-during-write":
    killed = False

    def killing_write(descriptor, content):
        global killed
        if not killed:
            killed = True
            real_write(descriptor, bytes(content[:4]))
            os.kill(os.getpid(), signal.SIGKILL)
        return real_write(descriptor, content)

    module.os.write = killing_write
    module.publish(target, "replace", binding, b"never partially visible\n")
    raise SystemExit("SIGKILL was not delivered")
elif mode == "fifo-open":
    target_name = os.path.basename(target)
    raced = False

    def swapping_lstat(path, *, dir_fd=None):
        global raced
        metadata = real_lstat(path, dir_fd=dir_fd)
        if not raced and os.fsdecode(path) == target_name:
            raced = True
            real_replace(target, original)
            os.mkfifo(target, 0o600)
        return metadata

    real_lstat = os.lstat
    module.os.lstat = swapping_lstat
    try:
        module.bind(target, "replace")
    except OSError:
        raise SystemExit(45)
    raise SystemExit("FIFO replacement was not rejected")
else:
    raise SystemExit("unknown publisher probe")
PY

run_generator() {
    local mode="$1"
    shift
    : > "$gh_log"
    set +e
    (
        cd "$fixture_repo" || exit 99
        unset BASH_ENV PYTHONHOME PYTHONSTARTUP
        if [ -n "${ODYSSEUS_TEST_PYTHONPATH:-}" ]; then
            export PYTHONPATH="$ODYSSEUS_TEST_PYTHONPATH"
        else
            unset PYTHONPATH
        fi
        ODYSSEUS_TEST_GH_LOG="$gh_log" \
        ODYSSEUS_TEST_GH_MODE="$mode" \
        PATH="$fixture_bin:$PATH" \
            "$GENERATOR_SHELL" "$ROOT/scripts/gen-ecosystem-table.sh" "$@"
    ) > "$fixture_root/stdout" 2> "$fixture_root/stderr"
    generator_status=$?
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

clear_publisher_race() {
    unset PYTHONPATH ODYSSEUS_TEST_PYTHONPATH ODYSSEUS_TEST_PUBLISH_RACE \
        ODYSSEUS_TEST_RACE_LOG ODYSSEUS_TEST_RACE_ORIGINAL \
        ODYSSEUS_TEST_RACE_TARGET ODYSSEUS_TEST_RACE_VICTIM \
        ODYSSEUS_TEST_SITECUSTOMIZE_MARKER
}

run_publisher_probe() {
    set +e
    env -u PYTHONPATH python3 -I -S "$publisher_probe" \
        "$ROOT/scripts/safe_report_publish.py" "$@"
    publisher_probe_status=$?
    set -e
}

run_publisher_timeout_probe() {
    set +e
    env -u PYTHONPATH python3 -I -S - "$publisher_probe" \
        "$ROOT/scripts/safe_report_publish.py" "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.executable, "-I", "-S", *sys.argv[1:]],
        check=False,
        timeout=2,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
    publisher_probe_status=$?
    set -e
}

info "report publication enforces one bounded-content ceiling before mutation"
publisher_size_root="$fixture_root/publisher-size"
mkdir "$publisher_size_root"
set +e
env -u PYTHONPATH python3 -I -S - \
    "$ROOT/scripts/safe_report_publish.py" "$publisher_size_root" <<'PY'
import importlib.util
import os
import subprocess
import sys

publisher_path, fixture_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("safe_report_publish_size", publisher_path)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
limit = publisher.MAX_REPORT_BYTES


def invoke(target, operation, token, content):
    return subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            publisher_path,
            "publish",
            target,
            operation,
            token,
        ],
        input=content,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


exact_target = os.path.join(fixture_root, "exact.md")
exact_token = publisher.bind(exact_target, "replace")
exact = b"x" * limit
if invoke(exact_target, "replace", exact_token, exact).returncode != 0:
    raise SystemExit("the exact report-size boundary was rejected")
with open(exact_target, "rb") as source:
    if source.read() != exact:
        raise SystemExit("the exact report-size boundary was not published")

stdin_target = os.path.join(fixture_root, "stdin-overflow.md")
with open(stdin_target, "wb") as destination:
    destination.write(b"stdin sentinel\n")
stdin_token = publisher.bind(stdin_target, "replace")
if invoke(stdin_target, "replace", stdin_token, b"y" * (limit + 1)).returncode != 2:
    raise SystemExit("boundary+1 stdin was not rejected")
with open(stdin_target, "rb") as source:
    if source.read() != b"stdin sentinel\n":
        raise SystemExit("boundary+1 stdin mutated the destination")

existing_target = os.path.join(fixture_root, "existing-overflow.md")
existing = b"z" * (limit + 1)
with open(existing_target, "wb") as destination:
    destination.write(existing)
try:
    publisher.bind(existing_target, "replace")
except OSError:
    pass
else:
    raise SystemExit("boundary+1 existing report was not rejected")
with open(existing_target, "rb") as source:
    if source.read() != existing:
        raise SystemExit("existing-report rejection mutated the destination")

append_target = os.path.join(fixture_root, "append-overflow.md")
append_original = b"a" * (limit - 1)
with open(append_target, "wb") as destination:
    destination.write(append_original)
append_token = publisher.bind(append_target, "append")
if invoke(append_target, "append", append_token, b"bc").returncode != 2:
    raise SystemExit("oversized built append content was not rejected")
with open(append_target, "rb") as source:
    if source.read() != append_original:
        raise SystemExit("built-content rejection mutated the destination")

budget_root = os.path.join(fixture_root, "quarantine-budget")
os.mkdir(budget_root)
budget_target = os.path.join(budget_root, "report.md")
with open(budget_target, "wb") as destination:
    destination.write(b"budget generation 0\n")
for generation in range(1, publisher.MAX_QUARANTINE_FILES + 1):
    token = publisher.bind(budget_target, "replace")
    publisher.publish(
        budget_target,
        "replace",
        token,
        f"budget generation {generation}\n".encode(),
    )
before_names = sorted(os.listdir(budget_root))
with open(budget_target, "rb") as source:
    before_content = source.read()
try:
    publisher.publish(
        budget_target,
        "replace",
        publisher.bind(budget_target, "replace"),
        b"budget overflow\n",
    )
except OSError:
    pass
else:
    raise SystemExit("quarantine count ceiling was not enforced")
if sorted(os.listdir(budget_root)) != before_names:
    raise SystemExit("quarantine rejection created another object")
with open(budget_target, "rb") as source:
    if source.read() != before_content:
        raise SystemExit("quarantine rejection mutated the destination")
PY
publisher_size_status=$?
set -e
if [ "$publisher_size_status" -eq 0 ]; then
    pass "report bytes and retained quarantine objects have inclusive ceilings"
else
    fail "report or quarantine bytes were unbounded or rejection mutated state"
fi

info "report binding rejects intermediate symlinks and ancestor route replacement"
publisher_route_root="$fixture_root/publisher-route"
publisher_route_direct="$publisher_route_root/direct/leaf"
publisher_route_external="$publisher_route_root/external/leaf"
mkdir -p "$publisher_route_direct" "$publisher_route_external"
printf '%s\n' 'external sentinel' > "$publisher_route_external/report.md"
ln -s "$publisher_route_external" "$publisher_route_root/link"
set +e
env -u PYTHONPATH python3 -I -S - \
    "$ROOT/scripts/safe_report_publish.py" \
    "$publisher_route_root/link/report.md" <<'PY'
import importlib.util
import sys

publisher_path, target = sys.argv[1:]
spec = importlib.util.spec_from_file_location("safe_report_publish_route", publisher_path)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
try:
    publisher.bind(target, "replace")
except OSError:
    raise SystemExit(0)
raise SystemExit("an intermediate symlink was accepted")
PY
publisher_symlink_status=$?
set -e
printf '%s\n' 'route sentinel' > "$publisher_route_direct/report.md"
publisher_route_token="$(env -u PYTHONPATH python3 -I -S \
    "$ROOT/scripts/safe_report_publish.py" bind \
    "$publisher_route_direct/report.md" replace)"
mv "$publisher_route_root/direct" "$publisher_route_root/direct.original"
ln -s "$publisher_route_root/direct.original" "$publisher_route_root/direct"
set +e
printf '%s\n' 'route replacement' \
    | env -u PYTHONPATH python3 -I -S \
        "$ROOT/scripts/safe_report_publish.py" publish \
        "$publisher_route_direct/report.md" replace "$publisher_route_token"
publisher_replaced_route_status=$?
set -e
if [ "$publisher_symlink_status" -eq 0 ] \
    && [ "$publisher_replaced_route_status" -eq 2 ] \
    && [ "$(cat "$publisher_route_external/report.md")" = 'external sentinel' ] \
    && [ "$(cat "$publisher_route_root/direct.original/leaf/report.md")" = \
        'route sentinel' ]; then
    pass "every lexical parent component remains direct and bound"
else
    fail "report publication followed or missed a replaced ancestor route"
fi

info "badges use the verified current default branch"
run_generator ok
if [ "$generator_status" -eq 0 ] \
    && grep -Fq '/trunk?nameFilter=build' "$fixture_root/stdout" \
    && ! grep -Fq '/main?nameFilter=' "$fixture_root/stdout"; then
    pass "current default branches are preserved in badge URLs"
else
    fail "the table did not use the verified default branch"
fi

info "all paginated check-run pages contribute to classification"
run_generator paged
if [ "$generator_status" -eq 0 ] \
    && grep -Fq 'nameFilter=security%2Fdependency-scan' "$fixture_root/stdout" \
    && grep -Fq -- '--paginate' "$gh_log" \
    && grep -Fq -- '--slurp' "$gh_log"; then
    pass "complete paginated check data is used"
else
    fail "later check-run pages were dropped"
fi

info "a verified empty check-run set is an ordinary category absence"
run_generator no-checks
if [ "$generator_status" -eq 0 ] \
    && grep -Fq '| [Atlas]' "$fixture_root/stdout" \
    && grep -Fq ' | — | — | — |' "$fixture_root/stdout"; then
    pass "no check runs remains distinct from an unavailable read"
else
    fail "a valid empty check-run set was rejected or misreported"
fi

info "unavailable branch data cannot publish any report sink"
output_path="$fixture_root/report.md"
inject_path="$fixture_root/README.md"
printf '%s\n' 'original output' > "$output_path"
cat > "$inject_path" <<'EOF'
before
<!-- ECOSYSTEM-CI-TABLE:START -->
old table
<!-- ECOSYSTEM-CI-TABLE:END -->
after
EOF
cp "$inject_path" "$fixture_root/README.before"
run_generator branch-unavailable --output "$output_path" --inject "$inject_path"
if [ "$generator_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original output' ] \
    && cmp -s "$inject_path" "$fixture_root/README.before"; then
    pass "unavailable branch data leaves stdout and files untouched"
else
    fail "unavailable branch data produced a partial report"
fi

info "incomplete paginated check data cannot become category gaps"
printf '%s\n' 'original output' > "$output_path"
run_generator checks-incomplete --output "$output_path"
if [ "$generator_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original output' ]; then
    pass "incomplete check pagination fails before publication"
else
    fail "incomplete check pagination was rendered as a table"
fi

info "malformed submodule inventory fails before publication"
cp "$fixture_repo/.gitmodules" "$fixture_root/gitmodules.valid"
printf '%s\n' '[submodule "broken"' > "$fixture_repo/.gitmodules"
printf '%s\n' 'original output' > "$output_path"
run_generator ok --output "$output_path"
mv "$fixture_root/gitmodules.valid" "$fixture_repo/.gitmodules"
if [ "$generator_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ "$(cat "$output_path")" = 'original output' ]; then
    pass "invalid canonical inventory is unavailable"
else
    fail "invalid inventory produced a partial table"
fi

info "output publication rejects symlink and nonregular targets"
external_target="$fixture_root/external.md"
printf '%s\n' 'external sentinel' > "$external_target"
ln -s "$external_target" "$fixture_root/output-link.md"
run_generator ok --output "$fixture_root/output-link.md"
symlink_status=$generator_status
mkdir "$fixture_root/output-directory"
run_generator ok --output "$fixture_root/output-directory"
directory_status=$generator_status
if [ "$symlink_status" -ne 0 ] \
    && [ "$directory_status" -ne 0 ] \
    && [ "$(cat "$external_target")" = 'external sentinel' ]; then
    pass "report targets are regular files and symlinks are not followed"
else
    fail "report publication followed or accepted an unsafe target"
fi

info "replace and injection cannot name the same report entry"
same_sink="$fixture_root/same-table-sink.md"
cat > "$same_sink" <<'EOF'
before
<!-- ECOSYSTEM-CI-TABLE:START -->
same table sentinel
<!-- ECOSYSTEM-CI-TABLE:END -->
after
EOF
cp "$same_sink" "$fixture_root/same-table-sink.before"
run_generator ok --output "$same_sink" --inject "$same_sink"
if [ "$generator_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && cmp -s "$same_sink" "$fixture_root/same-table-sink.before" \
    && [ ! -s "$gh_log" ]; then
    pass "same report sinks are rejected before any read or publication"
else
    fail "the table accepted identical replace and injection sinks"
fi

info "replace and marker injection preserve content and modes"
direct_output="$fixture_root/direct-output.md"
direct_inject="$fixture_root/direct-README.md"
printf '%s\n' 'replace sentinel' > "$direct_output"
cat > "$direct_inject" <<'EOF'
before
<!-- ECOSYSTEM-CI-TABLE:START -->
old table
<!-- ECOSYSTEM-CI-TABLE:END -->
after
EOF
chmod 0600 "$direct_output" "$direct_inject"
direct_output_original_inode="$(file_inode "$direct_output")"
direct_inject_original_inode="$(file_inode "$direct_inject")"
run_generator ok --output "$direct_output" --inject "$direct_inject"
if [ "$generator_status" -eq 0 ] \
    && grep -Fq '## Ecosystem CI Status' "$direct_output" \
    && ! grep -Fq 'replace sentinel' "$direct_output" \
    && grep -Fq 'before' "$direct_inject" \
    && grep -Fq 'after' "$direct_inject" \
    && [ "$(grep -Fc '<!-- ECOSYSTEM-CI-TABLE:START -->' "$direct_inject")" -eq 1 ] \
    && [ "$(grep -Fc '<!-- ECOSYSTEM-CI-TABLE:END -->' "$direct_inject")" -eq 1 ] \
    && grep -Fq '## Ecosystem CI Status' "$direct_inject" \
    && [ "$(file_mode "$direct_output")" = 0o600 ] \
    && [ "$(file_mode "$direct_inject")" = 0o600 ] \
    && [ "$(file_inode "$direct_output")" != "$direct_output_original_inode" ] \
    && [ "$(file_inode "$direct_inject")" != "$direct_inject_original_inode" ] \
    && find "$fixture_root" -maxdepth 1 -inum "$direct_output_original_inode" \
        -type f -print -quit | grep -q . \
    && find "$fixture_root" -maxdepth 1 -inum "$direct_inject_original_inode" \
        -type f -print -quit | grep -q .; then
    pass "replace and inject atomically publish while retaining old objects"
else
    fail "direct publication was non-atomic or lost its prior exact object"
fi

info "hardlinked replace and injection sinks are rejected"
hardlink_output_victim="$fixture_root/table-hardlink-output-victim.md"
hardlink_inject_victim="$fixture_root/table-hardlink-inject-victim.md"
printf '%s\n' 'output hardlink sentinel' > "$hardlink_output_victim"
cat > "$hardlink_inject_victim" <<'EOF'
before hardlink
<!-- ECOSYSTEM-CI-TABLE:START -->
old hardlink table
<!-- ECOSYSTEM-CI-TABLE:END -->
after hardlink
EOF
cp "$hardlink_output_victim" "$fixture_root/table-hardlink-output.before"
cp "$hardlink_inject_victim" "$fixture_root/table-hardlink-inject.before"
output_victim_inode="$(file_inode "$hardlink_output_victim")"
inject_victim_inode="$(file_inode "$hardlink_inject_victim")"
ln "$hardlink_output_victim" "$fixture_root/table-hardlink-output.md"
ln "$hardlink_inject_victim" "$fixture_root/table-hardlink-inject.md"
run_generator ok --output "$fixture_root/table-hardlink-output.md"
hardlink_output_status=$generator_status
run_generator ok --inject "$fixture_root/table-hardlink-inject.md"
if [ "$hardlink_output_status" -ne 0 ] \
    && [ "$generator_status" -ne 0 ] \
    && [ "$fixture_root/table-hardlink-output.md" -ef "$hardlink_output_victim" ] \
    && [ "$fixture_root/table-hardlink-inject.md" -ef "$hardlink_inject_victim" ] \
    && [ "$(file_inode "$hardlink_output_victim")" = "$output_victim_inode" ] \
    && [ "$(file_inode "$hardlink_inject_victim")" = "$inject_victim_inode" ] \
    && cmp -s "$hardlink_output_victim" "$fixture_root/table-hardlink-output.before" \
    && cmp -s "$hardlink_inject_victim" "$fixture_root/table-hardlink-inject.before"; then
    pass "multiply linked table sinks remain bound to unchanged victims"
else
    fail "a hardlinked table sink was accepted, detached, or changed"
fi

info "ambient Python startup code cannot execute in the trusted publisher"
ambient_parent="$fixture_root/ambient-python"
ambient_target="$ambient_parent/report.md"
ambient_marker="$ambient_parent/sitecustomize-loaded"
mkdir "$ambient_parent"
export ODYSSEUS_TEST_PYTHONPATH="$python_hooks"
export ODYSSEUS_TEST_SITECUSTOMIZE_MARKER="$ambient_marker"
run_generator ok --output "$ambient_target"
if [ "$generator_status" -eq 0 ] \
    && [ ! -e "$ambient_marker" ] \
    && grep -Fq '## Ecosystem CI Status' "$ambient_target"; then
    pass "report publication ignores ambient PYTHONPATH and sitecustomize"
else
    fail "ambient Python startup code executed in the report publisher"
fi
clear_publisher_race

info "venv site hooks cannot execute in report-generation Python"
venv_root="$fixture_root/hostile-venv"
venv_marker="$fixture_root/venv-sitecustomize-loaded"
venv_target="$fixture_root/venv-output.md"
python3 -m venv --without-pip "$venv_root"
venv_site="$("$venv_root/bin/python3" -I -c \
    'import site; print(site.getsitepackages()[0])')"
cat > "$venv_site/odysseus_startup_probe.py" <<'PY'
import os
import sys

marker = os.environ.get("ODYSSEUS_TEST_VENV_MARKER", "")
if marker and any(value in {"append", "inject", "replace"} for value in sys.argv):
    with open(marker, "a", encoding="utf-8") as destination:
        destination.write("venv sitecustomize loaded\n")
PY
printf '%s\n' 'import odysseus_startup_probe' > \
    "$venv_site/odysseus-startup-probe.pth"
original_path="$PATH"
export PATH="$venv_root/bin:$PATH"
export ODYSSEUS_TEST_VENV_MARKER="$venv_marker"
run_generator ok --output "$venv_target"
export PATH="$original_path"
unset ODYSSEUS_TEST_VENV_MARKER
if [ "$generator_status" -eq 0 ] \
    && [ ! -e "$venv_marker" ] \
    && grep -Fq '## Ecosystem CI Status' "$venv_target"; then
    pass "isolated no-site Python ignores venv startup hooks"
else
    fail "a venv site hook executed in report-generation Python"
fi

info "a newly created sink respects the caller's restrictive umask"
umask_parent="$fixture_root/restrictive-umask"
umask_target="$umask_parent/report.md"
mkdir "$umask_parent"
saved_umask="$(umask)"
umask 077
run_generator ok --output "$umask_target"
umask "$saved_umask"
if [ "$generator_status" -eq 0 ] \
    && [ "$(file_mode "$umask_target")" = 0o600 ] \
    && grep -Fq '## Ecosystem CI Status' "$umask_target"; then
    pass "exclusive creation does not widen the caller's requested mode"
else
    fail "new report publication widened a restrictive caller umask"
fi

info "a destination swap at the replace syscall cannot delete a victim"
replace_parent="$fixture_root/replace-syscall-race"
replace_target="$replace_parent/report.md"
replace_original="$replace_parent/report.original"
replace_victim="$replace_parent/report.victim"
mkdir "$replace_parent"
printf '%s\n' 'replace original' > "$replace_target"
printf '%s\n' 'replace victim' > "$replace_victim"
cp "$replace_victim" "$replace_parent/victim.before"
replace_victim_inode="$(file_inode "$replace_victim")"
export ODYSSEUS_TEST_PUBLISH_RACE=replace-syscall
export ODYSSEUS_TEST_RACE_TARGET="$replace_target"
export ODYSSEUS_TEST_RACE_ORIGINAL="$replace_original"
export ODYSSEUS_TEST_RACE_VICTIM="$replace_victim"
run_publisher_probe replace-syscall "$replace_target" "$replace_original" \
    "$replace_victim" "$replace_parent/syscall.log"
if [ "$publisher_probe_status" -eq 0 ] \
    && [ "$(cat "$replace_target")" = 'safe replacement' ] \
    && [ "$(file_inode "$replace_victim")" = "$replace_victim_inode" ] \
    && cmp -s "$replace_victim" "$replace_parent/victim.before" \
    && [ ! -e "$replace_parent/syscall.log" ]; then
    pass "the publication effect cannot replace a late-bound foreign victim"
else
    fail "the replace syscall removed or changed a late-bound victim"
fi
clear_publisher_race

info "a final exchange race preserves the displaced foreign object and fails"
exchange_parent="$fixture_root/final-exchange-race"
exchange_target="$exchange_parent/report.md"
exchange_original="$exchange_parent/report.original"
exchange_victim="$exchange_parent/report.victim"
exchange_log="$exchange_parent/exchange.log"
mkdir "$exchange_parent"
printf '%s\n' 'exchange original' > "$exchange_target"
printf '%s\n' 'exchange victim' > "$exchange_victim"
cp "$exchange_victim" "$exchange_parent/victim.before"
exchange_victim_inode="$(file_inode "$exchange_victim")"
run_publisher_probe existing-final-exchange-race "$exchange_target" \
    "$exchange_original" "$exchange_victim" "$exchange_log"
exchange_preserved="$(find "$exchange_parent" -maxdepth 1 \
    -inum "$exchange_victim_inode" -type f -print -quit)"
if [ "$publisher_probe_status" -eq 47 ] \
    && [ -e "$exchange_log" ] \
    && [ -n "$exchange_preserved" ] \
    && cmp -s "$exchange_preserved" "$exchange_parent/victim.before"; then
    pass "a foreign exchange victim is quarantined intact and never success"
else
    fail "a final exchange race lost a victim or reported false success"
fi

info "an exchanged candidate substitution is rolled back without object loss"
candidate_exchange_parent="$fixture_root/candidate-exchange-race"
candidate_exchange_target="$candidate_exchange_parent/report.md"
candidate_exchange_original="$candidate_exchange_parent/intended.candidate"
candidate_exchange_victim="$candidate_exchange_parent/foreign.victim"
candidate_exchange_log="$candidate_exchange_parent/exchange.log"
mkdir "$candidate_exchange_parent"
printf '%s\n' 'candidate exchange original' > "$candidate_exchange_target"
printf '%s\n' 'candidate exchange foreign' > "$candidate_exchange_victim"
cp "$candidate_exchange_target" "$candidate_exchange_parent/report.before"
cp "$candidate_exchange_victim" "$candidate_exchange_parent/victim.before"
candidate_exchange_victim_inode="$(file_inode "$candidate_exchange_victim")"
run_publisher_probe existing-candidate-exchange-race \
    "$candidate_exchange_target" "$candidate_exchange_original" \
    "$candidate_exchange_victim" "$candidate_exchange_log"
candidate_exchange_preserved="$(find "$candidate_exchange_parent" -maxdepth 1 \
    -inum "$candidate_exchange_victim_inode" -type f -print -quit)"
if [ "$publisher_probe_status" -eq 48 ] \
    && [ -e "$candidate_exchange_log" ] \
    && cmp -s "$candidate_exchange_target" \
        "$candidate_exchange_parent/report.before" \
    && [ -n "$candidate_exchange_preserved" ] \
    && cmp -s "$candidate_exchange_preserved" \
        "$candidate_exchange_parent/victim.before" \
    && [ "$(cat "$candidate_exchange_original")" = 'safe replacement' ]; then
    pass "candidate exchange substitution restores the prior exact target"
else
    fail "candidate exchange substitution reached the final target or lost bytes"
fi

info "an absent candidate substitution is quarantined and final absence restored"
candidate_absent_parent="$fixture_root/candidate-absent-race"
candidate_absent_target="$candidate_absent_parent/report.md"
candidate_absent_original="$candidate_absent_parent/intended.candidate"
candidate_absent_victim="$candidate_absent_parent/foreign.victim"
candidate_absent_log="$candidate_absent_parent/noreplace.log"
mkdir "$candidate_absent_parent"
printf '%s\n' 'candidate absent foreign' > "$candidate_absent_victim"
cp "$candidate_absent_victim" "$candidate_absent_parent/victim.before"
candidate_absent_victim_inode="$(file_inode "$candidate_absent_victim")"
run_publisher_probe absent-candidate-noreplace-race \
    "$candidate_absent_target" "$candidate_absent_original" \
    "$candidate_absent_victim" "$candidate_absent_log"
candidate_absent_preserved="$(find "$candidate_absent_parent" -maxdepth 1 \
    -inum "$candidate_absent_victim_inode" -type f -print -quit)"
if [ "$publisher_probe_status" -eq 49 ] \
    && [ -e "$candidate_absent_log" ] \
    && [ ! -e "$candidate_absent_target" ] \
    && [ -n "$candidate_absent_preserved" ] \
    && cmp -s "$candidate_absent_preserved" \
        "$candidate_absent_parent/victim.before" \
    && [ "$(cat "$candidate_absent_original")" = 'safe replacement' ]; then
    pass "candidate no-replace substitution restores final absence"
else
    fail "candidate no-replace substitution claimed the final name or lost bytes"
fi

info "final parent fsync failures roll publication back before reporting failure"
fsync_existing_parent="$fixture_root/existing-fsync-failure"
fsync_existing_target="$fsync_existing_parent/report.md"
fsync_existing_original="$fsync_existing_parent/unused.original"
fsync_existing_victim="$fsync_existing_parent/unused.victim"
fsync_existing_log="$fsync_existing_parent/unused.log"
mkdir "$fsync_existing_parent"
printf '%s\n' 'fsync existing original' > "$fsync_existing_target"
printf '%s\n' 'unused victim' > "$fsync_existing_victim"
cp "$fsync_existing_target" "$fsync_existing_parent/report.before"
run_publisher_probe existing-parent-fsync-failure "$fsync_existing_target" \
    "$fsync_existing_original" "$fsync_existing_victim" "$fsync_existing_log"
fsync_existing_status=$publisher_probe_status
fsync_absent_parent="$fixture_root/absent-fsync-failure"
fsync_absent_target="$fsync_absent_parent/report.md"
fsync_absent_original="$fsync_absent_parent/unused.original"
fsync_absent_victim="$fsync_absent_parent/unused.victim"
fsync_absent_log="$fsync_absent_parent/unused.log"
mkdir "$fsync_absent_parent"
printf '%s\n' 'unused victim' > "$fsync_absent_victim"
run_publisher_probe absent-parent-fsync-failure "$fsync_absent_target" \
    "$fsync_absent_original" "$fsync_absent_victim" "$fsync_absent_log"
if [ "$fsync_existing_status" -eq 50 ] \
    && cmp -s "$fsync_existing_target" "$fsync_existing_parent/report.before" \
    && [ "$publisher_probe_status" -eq 51 ] \
    && [ ! -e "$fsync_absent_target" ]; then
    pass "parent durability failure preserves prior target state"
else
    fail "parent durability failure leaked a committed target state"
fi

info "SIGKILL during candidate construction cannot expose partial report bytes"
kill_parent="$fixture_root/existing-sigkill-write"
kill_target="$kill_parent/report.md"
kill_original="$kill_parent/unused.original"
kill_victim="$kill_parent/unused.victim"
kill_log="$kill_parent/unused.log"
mkdir "$kill_parent"
printf '%s\n' 'kill-safe original' > "$kill_target"
printf '%s\n' 'unused victim' > "$kill_victim"
cp "$kill_target" "$kill_parent/report.before"
run_publisher_probe existing-sigkill-during-write "$kill_target" \
    "$kill_original" "$kill_victim" "$kill_log"
if [ "$publisher_probe_status" -eq 137 ] \
    && cmp -s "$kill_target" "$kill_parent/report.before"; then
    pass "abrupt termination leaves the bound destination wholly old"
else
    fail "abrupt termination exposed partially written destination bytes"
fi

info "table collection does not create a pathname-cleanup boundary"
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
TMPDIR="$runtime_tmp" run_generator ok
unset ODYSSEUS_TEST_CLEANUP_RACE_VICTIM \
    ODYSSEUS_TEST_CLEANUP_RACE_ORIGINAL ODYSSEUS_TEST_CLEANUP_RACE_LOG
if [ "$generator_status" -eq 0 ] \
    && [ "$(cat "$cleanup_race_victim/sentinel" 2>/dev/null)" = \
        'cleanup victim sentinel' ] \
    && [ ! -e "$cleanup_race_log" ] \
    && [ -z "$(find "$runtime_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    pass "table collection needs no temporary pathname or recursive cleanup"
else
    fail "table collection created a mutable temporary cleanup boundary"
fi

info "an absent sink is claimed with an exclusive creation syscall"
create_parent="$fixture_root/create-syscall-race"
create_target="$create_parent/report.md"
create_original="$create_parent/unused.original"
create_victim="$create_parent/report.victim"
create_log="$create_parent/syscall.log"
mkdir "$create_parent"
printf '%s\n' 'exclusive create victim' > "$create_victim"
cp "$create_victim" "$create_parent/victim.before"
create_victim_inode="$(file_inode "$create_victim")"
run_publisher_probe create-syscall "$create_target" "$create_original" \
    "$create_victim" "$create_log"
if [ "$publisher_probe_status" -eq 43 ] \
    && [ -e "$create_log" ] \
    && [ ! -e "$create_victim" ] \
    && [ "$(file_inode "$create_target")" = "$create_victim_inode" ] \
    && cmp -s "$create_target" "$create_parent/victim.before"; then
    pass "exclusive creation refuses a late-bound destination"
else
    fail "a late-bound destination was overwritten during creation"
fi

info "a regular-file to FIFO swap cannot block destination binding"
fifo_parent="$fixture_root/fifo-open-race"
fifo_target="$fifo_parent/report.md"
fifo_original="$fifo_parent/report.original"
fifo_victim="$fifo_parent/unused.victim"
fifo_log="$fifo_parent/unused.log"
mkdir "$fifo_parent"
printf '%s\n' 'FIFO original' > "$fifo_target"
printf '%s\n' 'FIFO unused victim' > "$fifo_victim"
cp "$fifo_target" "$fifo_parent/report.before"
cp "$fifo_victim" "$fifo_parent/victim.before"
run_publisher_timeout_probe fifo-open "$fifo_target" "$fifo_original" \
    "$fifo_victim" "$fifo_log"
if [ "$publisher_probe_status" -eq 45 ] \
    && [ -p "$fifo_target" ] \
    && cmp -s "$fifo_original" "$fifo_parent/report.before" \
    && cmp -s "$fifo_victim" "$fifo_parent/victim.before" \
    && [ ! -e "$fifo_log" ]; then
    pass "a FIFO substitution is rejected within the bounded probe"
else
    fail "a FIFO substitution blocked or escaped destination validation"
fi

info "an existing sink is restored after a transient write failure"
restore_parent="$fixture_root/existing-write-failure"
restore_target="$restore_parent/report.md"
restore_original="$restore_parent/unused.original"
restore_victim="$restore_parent/unused.victim"
restore_log="$restore_parent/unused.log"
mkdir "$restore_parent"
printf '%s\n' 'existing content that must survive' > "$restore_target"
printf '%s\n' 'unused victim' > "$restore_victim"
cp "$restore_target" "$restore_parent/report.before"
chmod 0600 "$restore_target"
run_publisher_probe existing-write-failure "$restore_target" "$restore_original" \
    "$restore_victim" "$restore_log"
if [ "$publisher_probe_status" -eq 44 ] \
    && cmp -s "$restore_target" "$restore_parent/report.before" \
    && [ "$(file_mode "$restore_target")" = 0o600 ]; then
    pass "a transient existing-sink write failure restores exact prior content"
else
    fail "a transient existing-sink write failure damaged the prior report"
fi

info "SIGINT cannot leave a partially overwritten existing sink"
signal_parent="$fixture_root/existing-signal-interrupt"
signal_target="$signal_parent/report.md"
signal_original="$signal_parent/unused.original"
signal_victim="$signal_parent/unused.victim"
signal_log="$signal_parent/unused.log"
mkdir "$signal_parent"
printf '%s\n' 'signal original that must remain atomic' > "$signal_target"
printf '%s\n' 'unused victim' > "$signal_victim"
cp "$signal_target" "$signal_parent/report.before"
run_publisher_probe existing-signal-interrupt "$signal_target" "$signal_original" \
    "$signal_victim" "$signal_log"
if [ "$publisher_probe_status" -eq 46 ] \
    && { cmp -s "$signal_target" "$signal_parent/report.before" \
        || [ "$(cat "$signal_target")" = 'signal-safe complete replacement' ]; }; then
    pass "SIGINT is delivered only after the existing sink is consistent"
else
    fail "SIGINT left a partially overwritten existing sink"
fi

info "an absent-sink write failure leaves no final name or deleted victim"
unlink_parent="$fixture_root/unlink-syscall-race"
unlink_target="$unlink_parent/report.md"
unlink_original="$unlink_parent/temporary.original"
unlink_victim="$unlink_parent/temporary.victim"
unlink_log="$unlink_parent/temporary-name.log"
mkdir "$unlink_parent"
printf '%s\n' 'unlink victim' > "$unlink_victim"
cp "$unlink_victim" "$unlink_parent/victim.before"
unlink_victim_inode="$(file_inode "$unlink_victim")"
export ODYSSEUS_TEST_PUBLISH_RACE=unlink-syscall
export ODYSSEUS_TEST_RACE_TARGET="$unlink_target"
export ODYSSEUS_TEST_RACE_ORIGINAL="$unlink_original"
export ODYSSEUS_TEST_RACE_VICTIM="$unlink_victim"
export ODYSSEUS_TEST_RACE_LOG="$unlink_log"
run_publisher_probe unlink-syscall "$unlink_target" "$unlink_original" \
    "$unlink_victim" "$unlink_log"
if [ "$publisher_probe_status" -eq 42 ] \
    && [ ! -e "$unlink_target" ] \
    && [ "$(file_inode "$unlink_victim")" = "$unlink_victim_inode" ] \
    && cmp -s "$unlink_victim" "$unlink_parent/victim.before" \
    && [ ! -e "$unlink_log" ]; then
    pass "failed construction retains evidence without claiming the final name"
else
    fail "failed construction exposed a partial sink or changed a victim"
fi
clear_publisher_race

summary
exit_code
