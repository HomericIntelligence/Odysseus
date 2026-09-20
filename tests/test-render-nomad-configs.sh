#!/usr/bin/env bash
# Hermetic behavior checks for explicit, parser-gated Nomad rendering.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
JUST_BIN="$(command -v just)"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-nomad-render.XXXXXX")"
fixture_bin="$fixture_root/bin"
effect_log="$fixture_root/effects"
mkdir -p "$fixture_bin"
cleanup_fixture() {
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove Nomad-render fixture: $fixture_root" >&2
    fi
}
trap cleanup_fixture EXIT

cat > "$fixture_bin/envsubst" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' envsubst >> "${ODYSSEUS_TEST_NOMAD_EFFECT_LOG:?}"
python3 -c '
import os
import sys

rendered = sys.stdin.read()
for name in ("NOMAD_SERVER_IP", "NOMAD_ADVERTISE_ADDR"):
    rendered = rendered.replace("${" + name + "}", os.environ[name])
sys.stdout.write(rendered)
'
status=$?
if [ "${ODYSSEUS_TEST_ENVSUBST_MODE:-ok}" = change-parent-mode ]; then
    chmod 770 "${ODYSSEUS_TEST_NOMAD_PARENT_PATH:?}"
fi
exit "$status"
EOF
chmod +x "$fixture_bin/envsubst"

# Keep the early authority checks independent of parser availability.
cat > "$fixture_bin/nomad" <<'EOF'
#!/usr/bin/env bash
printf 'nomad %s\n' "$*" >> "${ODYSSEUS_TEST_NOMAD_EFFECT_LOG:?}"
cat >/dev/null
EOF
chmod +x "$fixture_bin/nomad"

run_render() {
    local case_name=$1
    local command_path=${RUN_RENDER_PATH:-$fixture_bin:/usr/bin:/bin}
    local wrapper_bin="$fixture_root/wrappers-$case_name"
    local tool original helper argument variable value
    shift
    : > "$effect_log"
    mkdir "$wrapper_bin"
    for tool in envsubst nomad hclfmt; do
        original=""
        if ! original=$(PATH="$command_path" command -v "$tool" 2>/dev/null); then :; fi
        if [[ -z "$original" ]]; then
            continue
        fi
        {
            printf '%s\n' '#!/usr/bin/env bash'
            printf 'export ODYSSEUS_TEST_NOMAD_EFFECT_LOG=%q\n' "$effect_log"
            for argument in "$@"; do
                case "$argument" in
                    ODYSSEUS_TEST_*=*)
                        variable=${argument%%=*}
                        value=${argument#*=}
                        printf 'export %s=%q\n' "$variable" "$value"
                        ;;
                esac
            done
            printf 'exec %q "$@"\n' "$original"
        } > "$wrapper_bin/$tool"
        chmod +x "$wrapper_bin/$tool"
    done
    for helper in bash python3 sh; do
        original=""
        if ! original=$(PATH="$command_path:$PATH" command -v "$helper" 2>/dev/null); then :; fi
        if [[ -n "$original" ]]; then
            ln -s "$original" "$wrapper_bin/$helper"
        fi
    done
    set +e
    PATH="$wrapper_bin:$command_path" \
    ODYSSEUS_TEST_NOMAD_EFFECT_LOG="$effect_log" \
        "$@" >"$fixture_root/$case_name.out" 2>&1
    render_status=$?
    set -e
}

inode_of() {
    "$(command -v python3)" -c \
        'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

identity_of() {
    "$(command -v python3)" -c \
        'import os, sys; value=os.lstat(sys.argv[1]); print(f"{value.st_dev}:{value.st_ino}")' \
        "$1"
}

mode_of() {
    "$(command -v python3)" -c \
        'import os, stat, sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))[2:])' \
        "$1"
}

state_of() {
    "$(command -v python3)" -c '
import os
import stat
import sys

value = os.lstat(sys.argv[1])
print(
    f"{value.st_dev}:{value.st_ino}:{value.st_nlink}:{value.st_size}:"
    f"{stat.S_IMODE(value.st_mode):o}:{value.st_mtime_ns}:{value.st_ctime_ns}"
)
' "$1"
}

prepare_approved_directory() {
    mkdir -m 700 "$1" || return 1
    identity_of "$1"
}

directory_is_empty() {
    [ -d "$1" ] && [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

process_is_gone() {
    local pid=$1
    local _
    for _ in {1..40}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

if [ "$(python3 -c 'import sys; print("linux" if sys.platform.startswith("linux") else "other")')" != linux ]; then
    info "non-Linux hosts reject descriptor execution before running selected tools"
    unsupported_out="$fixture_root/unsupported-platform"
    unsupported_id=$(prepare_approved_directory "$unsupported_out")
    run_render unsupported-platform env \
        NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
        NOMAD_RENDER_APPROVED_DIR="$unsupported_out" \
        NOMAD_RENDER_APPROVED_ID="$unsupported_id" \
        "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs \
        "$unsupported_out"
    if [ "$render_status" -ne 0 ] \
        && grep -Fq 'Linux descriptor execution is required' \
            "$fixture_root/unsupported-platform.out" \
        && [ ! -s "$effect_log" ] \
        && directory_is_empty "$unsupported_out"; then
        pass "non-Linux execution fails closed before selected-tool effects"
    else
        sed 's/^/    /' "$fixture_root/unsupported-platform.out" >&2
        fail "non-Linux execution reached a selected tool or changed output"
    fi
    summary
    if exit_code; then
        exit 0
    fi
    exit 1
fi

info "termination cleanup preserves timeout and active failures"
if python3 - "$ROOT/scripts/render_nomad_configs.py" <<'PY'
import importlib.util
from unittest import mock
import sys

spec = importlib.util.spec_from_file_location("renderer", sys.argv[1])
assert spec and spec.loader
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class Probe:
    def __init__(self, name, events):
        self.name = name
        self.events = events

    def write(self, _content):
        pass

    def seek(self, _offset):
        pass

    def close(self):
        self.events.append(self.name)


class Process:
    pid = 991
    returncode = -15

    def __init__(self, events):
        self.stdout = Probe("stdout", events)
        self.stderr = Probe("stderr", events)

    def poll(self):
        return None


for primary in ("pending", "active"):
    events = []
    process = Process(events)

    class Selector(Probe):
        def register(self, *_args):
            pass

        def get_map(self):
            return {}

        def select(self, _timeout):
            if primary == "active":
                raise RuntimeError("active primary")
            return []

    class Executable:
        name = "validator"

        def verify(self):
            events.append("verify")

    def boundary():
        events.append("boundary")

    with (
        mock.patch.object(renderer.selectors, "DefaultSelector", return_value=Selector("selector", events)),
        mock.patch.object(renderer.tempfile, "TemporaryFile", return_value=Probe("stdin", events)),
        mock.patch.object(renderer, "popen_bound", return_value=process),
        mock.patch.object(renderer, "terminate_process_group", side_effect=PermissionError("termination denied")) as terminator,
        mock.patch.object(renderer.time, "monotonic", side_effect=(0.0, 0.0, 2.0) if primary == "pending" else (0.0, 0.0, 0.0)),
    ):
        try:
            renderer.run_supervised(Executable(), (), b"", boundary, deadline=1.0)
        except RuntimeError as error:
            expected = "timed out" if primary == "pending" else "active primary"
            assert expected in str(error), error
        else:
            raise AssertionError("termination failure replaced no primary")
    assert events[-6:] == ["selector", "stdin", "stdout", "stderr", "verify", "boundary"], events
    assert terminator.call_args_list == [mock.call(process)], terminator.call_args_list
PY
then
    pass "termination cleanup does not mask timeout or active failure"
else
    fail "termination cleanup masked a primary failure or skipped finalizers"
fi

info "rendering requires an explicit output directory"
run_render no-output "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs
if [ "$render_status" -ne 0 ] \
    && grep -Eq 'OUT_DIR|output director' "$fixture_root/no-output.out" \
    && [ ! -s "$effect_log" ]; then
    pass "missing output directory stops before effects"
else
    fail "rendering retained an implicit output destination"
fi

info "an exact approved destination is required"
mismatch_out="$fixture_root/mismatch"
mismatch_id=$(prepare_approved_directory "$mismatch_out")
mismatch_state=$(state_of "$mismatch_out")
run_render mismatch env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$fixture_root/different" \
    NOMAD_RENDER_APPROVED_ID="$mismatch_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$mismatch_out"
if [ "$render_status" -ne 0 ] && directory_is_empty "$mismatch_out"; then
    if grep -Fq \
        'ERROR: NOMAD_RENDER_APPROVED_DIR does not match the exact output directory' \
        "$fixture_root/mismatch.out" \
        && [ ! -s "$effect_log" ] \
        && [ "$(identity_of "$mismatch_out")" = "$mismatch_id" ] \
        && [ "$(mode_of "$mismatch_out")" = 700 ] \
        && [ "$(state_of "$mismatch_out")" = "$mismatch_state" ]; then
        pass "destination approval mismatch stops before parser or filesystem effects"
    else
        sed 's/^/    /' "$fixture_root/mismatch.out" >&2
        fail "destination approval mismatch did not fail at the authority boundary"
    fi
else
    fail "destination approval mismatch created rendered state"
fi

info "the output identity receipt is required"
missing_id_out="$fixture_root/missing-id"
prepare_approved_directory "$missing_id_out" >/dev/null
run_render missing-id env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$missing_id_out" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$missing_id_out"
if [ "$render_status" -ne 0 ] \
    && grep -Fq 'NOMAD_RENDER_APPROVED_ID' "$fixture_root/missing-id.out" \
    && [ ! -s "$effect_log" ] \
    && directory_is_empty "$missing_id_out"; then
    pass "a missing output identity receipt stops before effects"
else
    sed 's/^/    /' "$fixture_root/missing-id.out" >&2
    fail "rendering accepted a missing output identity receipt"
fi

info "the output identity receipt must name the approved directory"
wrong_id_out="$fixture_root/wrong-id"
wrong_id_other="$fixture_root/wrong-id-other"
prepare_approved_directory "$wrong_id_out" >/dev/null
wrong_id=$(prepare_approved_directory "$wrong_id_other")
run_render wrong-id env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$wrong_id_out" \
    NOMAD_RENDER_APPROVED_ID="$wrong_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$wrong_id_out"
if [ "$render_status" -ne 0 ] \
    && [ ! -s "$effect_log" ] \
    && directory_is_empty "$wrong_id_out"; then
    pass "a receipt for a different directory stops before effects"
else
    sed 's/^/    /' "$fixture_root/wrong-id.out" >&2
    fail "rendering accepted a different directory identity"
fi

info "an unavailable parser cannot produce rendered files"
missing_parser_out="$fixture_root/missing-parser"
missing_parser_id=$(prepare_approved_directory "$missing_parser_out")
missing_parser_bin="$fixture_root/missing-parser-bin"
mkdir "$missing_parser_bin"
ln -s "$(command -v bash)" "$missing_parser_bin/bash"
ln -s "$(command -v env)" "$missing_parser_bin/env"
ln -s "$(command -v python3)" "$missing_parser_bin/python3"
ln -s "$fixture_bin/envsubst" "$missing_parser_bin/envsubst"
RUN_RENDER_PATH="$missing_parser_bin" run_render missing-parser env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$missing_parser_out" \
    NOMAD_RENDER_APPROVED_ID="$missing_parser_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$missing_parser_out"
if [ "$render_status" -ne 0 ] \
    && grep -Eqi 'parser|nomad|hclfmt' "$fixture_root/missing-parser.out" \
    && directory_is_empty "$missing_parser_out"; then
    pass "missing HCL parser is unavailable before output writes"
else
    fail "missing HCL parser was skipped or left output state"
fi

cat > "$fixture_bin/nomad" <<'EOF'
#!/usr/bin/env bash
printf 'nomad %s\n' "$*" >> "${ODYSSEUS_TEST_NOMAD_EFFECT_LOG:?}"
case "${ODYSSEUS_TEST_NOMAD_MODE:-ok}" in
  ok) cat >/dev/null; exit 0 ;;
  fail) cat >/dev/null; exit 1 ;;
  plant-directory)
    cat >/dev/null
    if [ ! -e "${ODYSSEUS_TEST_NOMAD_ONCE:?}" ]; then
      : > "$ODYSSEUS_TEST_NOMAD_ONCE"
      printf '%s\n' 'destination victim' \
        > "${ODYSSEUS_TEST_NOMAD_RACE_TARGET:?}/victim"
      python3 -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' \
        "$ODYSSEUS_TEST_NOMAD_RACE_TARGET/victim" \
        > "${ODYSSEUS_TEST_NOMAD_VICTIM_INODE:?}"
    fi
    exit 0
    ;;
  change-output-mode)
    cat >/dev/null
    chmod 755 "${ODYSSEUS_TEST_NOMAD_RACE_TARGET:?}"
    exit 0
    ;;
  change-parent-mode)
    cat >/dev/null
    chmod 770 "${ODYSSEUS_TEST_NOMAD_PARENT_PATH:?}"
    exit 0
    ;;
  swap-ancestor)
    cat >/dev/null
    if [ ! -e "${ODYSSEUS_TEST_NOMAD_ONCE:?}" ]; then
      : > "$ODYSSEUS_TEST_NOMAD_ONCE"
      parent_dir=${ODYSSEUS_TEST_NOMAD_PARENT_PATH:?}
      mv "$parent_dir" "${ODYSSEUS_TEST_NOMAD_DISPLACED_PARENT:?}"
      mkdir -p "$parent_dir"
      mkdir -p "${ODYSSEUS_TEST_NOMAD_RACE_TARGET:?}"
      printf '%s\n' 'replacement-parent victim' \
        > "$ODYSSEUS_TEST_NOMAD_RACE_TARGET/victim"
      python3 -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' \
        "$ODYSSEUS_TEST_NOMAD_RACE_TARGET/victim" \
        > "${ODYSSEUS_TEST_NOMAD_VICTIM_INODE:?}"
    fi
    exit 0
    ;;
  mutate-source)
    cat >/dev/null
    if [ ! -e "${ODYSSEUS_TEST_NOMAD_ONCE:?}" ]; then
      : > "$ODYSSEUS_TEST_NOMAD_ONCE"
      printf '%s\n' '# parser-time source mutation' \
        > "${ODYSSEUS_TEST_NOMAD_SOURCE_FILE:?}"
    fi
    exit 0
    ;;
  swap-source-restore)
    count=1
    if [ -e "${ODYSSEUS_TEST_NOMAD_COUNT:?}" ]; then
      count=$(cat "$ODYSSEUS_TEST_NOMAD_COUNT")
    fi
    case "$count" in
      1) config_name=client.hcl ;;
      2) config_name=server.hcl ;;
      *) exit 94 ;;
    esac
    source_file="${ODYSSEUS_TEST_NOMAD_SOURCE_DIR:?}/$config_name"
    saved_file="${source_file}.bound"
    received_file="${ODYSSEUS_TEST_NOMAD_RECEIVED_DIR:?}/$config_name"
    mv "$source_file" "$saved_file"
    printf '%s\n' 'hostile substitute path bytes' > "$source_file"
    cat > "$received_file"
    rm -f -- "$source_file"
    mv "$saved_file" "$source_file"
    cmp -s "$received_file" \
      "${ODYSSEUS_TEST_NOMAD_EXPECTED_DIR:?}/$config_name" || exit 95
    printf '%s\n' "$((count + 1))" > "$ODYSSEUS_TEST_NOMAD_COUNT"
    exit 0
    ;;
  *) exit 93 ;;
esac
EOF
chmod +x "$fixture_bin/nomad"

cat > "$fixture_root/inject-tool-swap.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import sys

module_path, source, output, stage, hostile = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def selected_path(value):
    if hasattr(value, "selected_path"):
        return value.selected_path
    if hasattr(value, "executable"):
        return value.executable.selected_path
    if isinstance(value, list):
        return value[0]
    return value


def replace_selected(value):
    path = selected_path(value)
    os.rename(path, path + ".selected")
    os.rename(hostile, path)


if stage == "render":
    real_render = renderer.render_sources

    def injected_render(
        source_directory, values, envsubst, child_boundary, **kwargs
    ):
        replace_selected(envsubst)
        return real_render(
            source_directory, values, envsubst, child_boundary, **kwargs
        )

    renderer.render_sources = injected_render
elif stage == "parser":
    real_validate = renderer.validate_rendered

    def injected_validate(parser_command, rendered, child_boundary, **kwargs):
        replace_selected(parser_command)
        return real_validate(
            parser_command, rendered, child_boundary, **kwargs
        )

    renderer.validate_rendered = injected_validate
elif stage == "snapshot-parent":
    real_popen = renderer.popen_bound
    swapped = False

    def injected_popen(executable, arguments, **kwargs):
        global swapped
        if executable.name == "envsubst" and not swapped:
            swapped = True
            snapshot = Path(executable.snapshot_directory)
            snapshot.rename(snapshot.with_name(snapshot.name + ".bound"))
            snapshot.mkdir(mode=0o700)
            shutil.copyfile(hostile, snapshot / executable.snapshot_name)
            os.chmod(snapshot / executable.snapshot_name, 0o500)
        return real_popen(executable, arguments, **kwargs)

    renderer.popen_bound = injected_popen
elif stage == "snapshot-leaf":
    real_popen = renderer.popen_bound
    swapped = False

    def injected_popen(executable, arguments, **kwargs):
        global swapped
        if executable.name == "envsubst" and not swapped:
            swapped = True
            os.fchmod(executable.directory_descriptor, 0o700)
            os.rename(
                executable.snapshot_name,
                executable.snapshot_name + ".selected",
                src_dir_fd=executable.directory_descriptor,
                dst_dir_fd=executable.directory_descriptor,
            )
            descriptor = os.open(
                executable.snapshot_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o500,
                dir_fd=executable.directory_descriptor,
            )
            try:
                with open(hostile, "rb") as source:
                    os.write(descriptor, source.read())
            finally:
                os.close(descriptor)
            os.fchmod(executable.directory_descriptor, 0o500)
        try:
            return real_popen(executable, arguments, **kwargs)
        finally:
            if swapped:
                os.fchmod(executable.directory_descriptor, 0o700)
                try:
                    os.unlink(
                        executable.snapshot_name + ".selected",
                        dir_fd=executable.directory_descriptor,
                    )
                except FileNotFoundError:
                    pass
                os.fchmod(executable.directory_descriptor, 0o500)

    renderer.popen_bound = injected_popen
elif stage == "shebang-path":
    real_render = renderer.render_sources

    def injected_render(
        source_directory, values, envsubst, child_boundary, **kwargs
    ):
        bash_path = Path(selected_path(envsubst)).parent / "bash"
        bash_path.unlink()
        shutil.copyfile(hostile, bash_path)
        os.chmod(bash_path, 0o700)
        return real_render(
            source_directory, values, envsubst, child_boundary, **kwargs
        )

    renderer.render_sources = injected_render
else:
    raise RuntimeError(f"unsupported swap stage: {stage}")

sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
raise SystemExit(renderer.main())
PY

cat > "$fixture_root/run-renderer-with-limits.py" <<'PY'
import importlib.util
import sys

module_path, source, output = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
renderer.COMMAND_TIMEOUT_SECONDS = 0.3
renderer.TERM_GRACE_SECONDS = 0.1
renderer.KILL_GRACE_SECONDS = 0.5
renderer.OUTPUT_LIMIT_BYTES = 32 * 1024
sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
raise SystemExit(renderer.main())
PY

cat > "$fixture_root/run-with-deadline.py" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=1)
    print("ERROR: test deadline exceeded", file=sys.stderr)
    raise SystemExit(124)
PY

info "a selected render executable cannot be replaced before execution"
render_swap_bin="$fixture_root/render-swap-bin"
render_swap_hostile="$fixture_root/render-swap-hostile"
render_swap_sentinel="$fixture_root/render-swap.sentinel"
render_swap_parent="$fixture_root/render-swap-parent"
render_swap_out="$render_swap_parent/rendered"
mkdir "$render_swap_bin" "$render_swap_parent"
cp "$fixture_bin/envsubst" "$render_swap_bin/envsubst"
cp "$fixture_bin/nomad" "$render_swap_bin/nomad"
ln -s "$(command -v bash)" "$render_swap_bin/bash"
ln -s "$(command -v python3)" "$render_swap_bin/python3"
cat > "$render_swap_hostile" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' hostile-render >> "${ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL:?}"
python3 -c '
import os
import sys

rendered = sys.stdin.read()
for name in ("NOMAD_SERVER_IP", "NOMAD_ADVERTISE_ADDR"):
    rendered = rendered.replace("${" + name + "}", os.environ[name])
sys.stdout.write(rendered)
'
EOF
chmod +x "$render_swap_hostile"
render_swap_id=$(prepare_approved_directory "$render_swap_out")
RUN_RENDER_PATH="$render_swap_bin:/usr/bin:/bin" run_render render-swap env \
    ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL="$render_swap_sentinel" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$render_swap_out" \
    NOMAD_RENDER_APPROVED_ID="$render_swap_id" \
    python3 "$fixture_root/inject-tool-swap.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$render_swap_out" render "$render_swap_hostile"
if [ "$render_status" -eq 0 ] \
    && [ ! -e "$render_swap_sentinel" ] \
    && [ -f "$render_swap_out/client.hcl" ] \
    && [ -f "$render_swap_out/server.hcl" ]; then
    pass "rendering executes the selected bytes after a pathname replacement"
else
    sed 's/^/    /' "$fixture_root/render-swap.out" >&2
    fail "a replacement render executable ran after selection"
fi

info "a selected parser executable cannot be replaced before execution"
parser_swap_bin="$fixture_root/parser-swap-bin"
parser_swap_hostile="$fixture_root/parser-swap-hostile"
parser_swap_sentinel="$fixture_root/parser-swap.sentinel"
parser_swap_parent="$fixture_root/parser-swap-parent"
parser_swap_out="$parser_swap_parent/rendered"
mkdir "$parser_swap_bin" "$parser_swap_parent"
cp "$fixture_bin/envsubst" "$parser_swap_bin/envsubst"
cp "$fixture_bin/nomad" "$parser_swap_bin/nomad"
ln -s "$(command -v bash)" "$parser_swap_bin/bash"
ln -s "$(command -v python3)" "$parser_swap_bin/python3"
cat > "$parser_swap_hostile" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' hostile-parser >> "${ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL:?}"
cat >/dev/null
EOF
chmod +x "$parser_swap_hostile"
parser_swap_id=$(prepare_approved_directory "$parser_swap_out")
RUN_RENDER_PATH="$parser_swap_bin:/usr/bin:/bin" run_render parser-swap env \
    ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL="$parser_swap_sentinel" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$parser_swap_out" \
    NOMAD_RENDER_APPROVED_ID="$parser_swap_id" \
    python3 "$fixture_root/inject-tool-swap.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$parser_swap_out" parser "$parser_swap_hostile"
if [ "$render_status" -eq 0 ] \
    && [ ! -e "$parser_swap_sentinel" ] \
    && [ -f "$parser_swap_out/client.hcl" ] \
    && [ -f "$parser_swap_out/server.hcl" ]; then
    pass "parsing executes the selected bytes after a pathname replacement"
else
    sed 's/^/    /' "$fixture_root/parser-swap.out" >&2
    fail "a replacement parser executable ran after selection"
fi

info "a snapshot-parent replacement cannot redirect execution"
snapshot_bin="$fixture_root/snapshot-bin"
snapshot_hostile="$fixture_root/snapshot-hostile"
snapshot_sentinel="$fixture_root/snapshot.sentinel"
snapshot_out="$fixture_root/snapshot-out"
mkdir "$snapshot_bin"
cp "$fixture_bin/envsubst" "$snapshot_bin/envsubst"
cp "$fixture_bin/nomad" "$snapshot_bin/nomad"
ln -s "$(command -v bash)" "$snapshot_bin/bash"
ln -s "$(command -v python3)" "$snapshot_bin/python3"
cat > "$snapshot_hostile" <<'EOF'
#!/bin/sh
printf '%s\n' hostile-snapshot > "${ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL:?}"
exit 91
EOF
chmod +x "$snapshot_hostile"
snapshot_id=$(prepare_approved_directory "$snapshot_out")
RUN_RENDER_PATH="$snapshot_bin:/usr/bin:/bin" run_render snapshot-parent env \
    ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL="$snapshot_sentinel" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$snapshot_out" \
    NOMAD_RENDER_APPROVED_ID="$snapshot_id" \
    python3 "$fixture_root/inject-tool-swap.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$snapshot_out" snapshot-parent "$snapshot_hostile"
if [ "$render_status" -eq 0 ] \
    && [ ! -e "$snapshot_sentinel" ] \
    && [ -f "$snapshot_out/client.hcl" ] \
    && [ -f "$snapshot_out/server.hcl" ]; then
    pass "descriptor-relative execution survives a snapshot-parent replacement"
else
    sed 's/^/    /' "$fixture_root/snapshot-parent.out" >&2
    fail "a snapshot-parent replacement redirected execution"
fi

info "a snapshot-leaf replacement cannot execute hostile bytes"
leaf_bin="$fixture_root/leaf-bin"
leaf_hostile="$fixture_root/leaf-hostile"
leaf_sentinel="$fixture_root/leaf.sentinel"
leaf_out="$fixture_root/leaf-out"
mkdir "$leaf_bin"
cp "$fixture_bin/envsubst" "$leaf_bin/envsubst"
cp "$fixture_bin/nomad" "$leaf_bin/nomad"
ln -s "$(command -v bash)" "$leaf_bin/bash"
ln -s "$(command -v python3)" "$leaf_bin/python3"
cat > "$leaf_hostile" <<'EOF'
#!/bin/sh
printf '%s\n' hostile-leaf > "${ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL:?}"
exit 90
EOF
chmod +x "$leaf_hostile"
leaf_id=$(prepare_approved_directory "$leaf_out")
RUN_RENDER_PATH="$leaf_bin:/usr/bin:/bin" run_render snapshot-leaf env \
    ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL="$leaf_sentinel" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$leaf_out" \
    NOMAD_RENDER_APPROVED_ID="$leaf_id" \
    python3 "$fixture_root/inject-tool-swap.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$leaf_out" snapshot-leaf "$leaf_hostile"
if [ "$render_status" -ne 0 ] \
    && [ ! -e "$leaf_sentinel" ] \
    && directory_is_empty "$leaf_out"; then
    pass "a newly opened snapshot leaf is verified before descriptor execution"
else
    sed 's/^/    /' "$fixture_root/snapshot-leaf.out" >&2
    fail "a replacement snapshot leaf executed hostile bytes"
fi

info "a shebang PATH replacement cannot select an unbound interpreter"
shebang_bin="$fixture_root/shebang-bin"
shebang_hostile="$fixture_root/shebang-hostile"
shebang_sentinel="$fixture_root/shebang.sentinel"
shebang_out="$fixture_root/shebang-out"
mkdir "$shebang_bin"
cp "$fixture_bin/envsubst" "$shebang_bin/envsubst"
cp "$fixture_bin/nomad" "$shebang_bin/nomad"
ln -s "$(command -v bash)" "$shebang_bin/bash"
ln -s "$(command -v python3)" "$shebang_bin/python3"
cat > "$shebang_hostile" <<'EOF'
#!/bin/sh
printf '%s\n' hostile-interpreter > "${ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL:?}"
exit 92
EOF
chmod +x "$shebang_hostile"
shebang_id=$(prepare_approved_directory "$shebang_out")
RUN_RENDER_PATH="$shebang_bin:/usr/bin:/bin" run_render shebang-path env \
    ODYSSEUS_TEST_NOMAD_SWAP_SENTINEL="$shebang_sentinel" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$shebang_out" \
    NOMAD_RENDER_APPROVED_ID="$shebang_id" \
    python3 "$fixture_root/inject-tool-swap.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$shebang_out" shebang-path "$shebang_hostile"
if [ "$render_status" -eq 0 ] \
    && [ ! -e "$shebang_sentinel" ] \
    && [ -f "$shebang_out/client.hcl" ] \
    && [ -f "$shebang_out/server.hcl" ]; then
    pass "script execution uses the separately bound interpreter"
else
    sed 's/^/    /' "$fixture_root/shebang-path.out" >&2
    fail "a PATH swap selected an unbound shebang interpreter"
fi

info "a timed-out tool cannot retain a TERM-ignoring descendant"
timeout_bin="$fixture_root/timeout-bin"
timeout_parent="$fixture_root/timeout-parent"
timeout_out="$timeout_parent/rendered"
timeout_child_pid="$fixture_root/timeout-child.pid"
mkdir "$timeout_bin" "$timeout_parent"
cat > "$timeout_bin/envsubst" <<'EOF'
#!/usr/bin/env bash
bash -c '
trap "" TERM
printf "%s\n" "$$" > "${ODYSSEUS_TEST_NOMAD_CHILD_PID:?}"
while :; do sleep 1; done
' &
wait "$!"
EOF
chmod +x "$timeout_bin/envsubst"
cp "$fixture_bin/nomad" "$timeout_bin/nomad"
ln -s "$(command -v bash)" "$timeout_bin/bash"
ln -s "$(command -v python3)" "$timeout_bin/python3"
timeout_id=$(prepare_approved_directory "$timeout_out")
RUN_RENDER_PATH="$timeout_bin:/usr/bin:/bin" run_render timeout-tree env \
    ODYSSEUS_TEST_NOMAD_CHILD_PID="$timeout_child_pid" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$timeout_out" \
    NOMAD_RENDER_APPROVED_ID="$timeout_id" \
    python3 "$fixture_root/run-with-deadline.py" 3 \
      python3 "$fixture_root/run-renderer-with-limits.py" \
        "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
        "$timeout_out"
timeout_descendant=""
if [ -s "$timeout_child_pid" ]; then
    timeout_descendant=$(cat "$timeout_child_pid")
fi
if [ "$render_status" -ne 0 ] \
    && grep -Fqi 'timed out' "$fixture_root/timeout-tree.out" \
    && [ -n "$timeout_descendant" ] \
    && process_is_gone "$timeout_descendant" \
    && directory_is_empty "$timeout_out"; then
    pass "timeout escalation reaps the child and extinguishes its process group"
else
    sed 's/^/    /' "$fixture_root/timeout-tree.out" >&2
    if [ -n "$timeout_descendant" ] && kill -0 "$timeout_descendant" 2>/dev/null; then
        kill -KILL "$timeout_descendant" 2>/dev/null
    fi
    fail "a timed-out tool retained a TERM-ignoring descendant"
fi

info "TERM and HUP cannot orphan a TERM-ignoring tool descendant"
for signal_case in TERM:143 HUP:129; do
    signal_name=${signal_case%%:*}
    expected_status=${signal_case##*:}
    signal_bin="$fixture_root/signal-$signal_name-bin"
    signal_out="$fixture_root/signal-$signal_name-out"
    signal_pid_file="$fixture_root/signal-$signal_name-child.pid"
    signal_log="$fixture_root/signal-$signal_name.out"
    mkdir "$signal_bin"
    cat > "$signal_bin/envsubst" <<'EOF'
#!/bin/sh
sh -c '
trap "" TERM HUP
printf "%s\n" "$$" > "${ODYSSEUS_TEST_NOMAD_CHILD_PID:?}"
while :; do sleep 1; done
' &
wait "$!"
EOF
    chmod +x "$signal_bin/envsubst"
    cp "$fixture_bin/nomad" "$signal_bin/nomad"
    ln -s "$(command -v bash)" "$signal_bin/bash"
    ln -s "$(command -v python3)" "$signal_bin/python3"
    signal_id=$(prepare_approved_directory "$signal_out")
    PATH="$signal_bin:/usr/bin:/bin" \
    ODYSSEUS_TEST_NOMAD_EFFECT_LOG="$effect_log" \
    ODYSSEUS_TEST_NOMAD_CHILD_PID="$signal_pid_file" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$signal_out" \
    NOMAD_RENDER_APPROVED_ID="$signal_id" \
        python3 "$ROOT/scripts/render_nomad_configs.py" \
          --source-dir "$ROOT/configs/nomad" --output-dir "$signal_out" \
          >"$signal_log" 2>&1 &
    renderer_pid=$!
    signal_descendant=""
    for _ in {1..40}; do
        if [ -s "$signal_pid_file" ]; then
            signal_descendant=$(cat "$signal_pid_file")
            break
        fi
        sleep 0.05
    done
    kill -"$signal_name" "$renderer_pid"
    set +e
    wait "$renderer_pid"
    signal_status=$?
    set -e
    if [ "$signal_status" -eq "$expected_status" ] \
        && [ -n "$signal_descendant" ] \
        && process_is_gone "$signal_descendant" \
        && directory_is_empty "$signal_out"; then
        pass "$signal_name is re-raised after process-group extinction"
    else
        sed 's/^/    /' "$signal_log" >&2
        if [ -n "$signal_descendant" ] && kill -0 "$signal_descendant" 2>/dev/null; then
            kill -KILL "$signal_descendant" 2>/dev/null
        fi
        fail "$signal_name orphaned a tool descendant or skipped cleanup"
    fi
done

info "a successful tool cannot exceed the diagnostic output bound"
flood_bin="$fixture_root/flood-bin"
flood_out="$fixture_root/flood-out"
mkdir "$flood_bin"
cat > "$flood_bin/envsubst" <<'EOF'
#!/usr/bin/env bash
python3 -c 'import sys; sys.stderr.buffer.write(b"x" * (2 * 1024 * 1024))'
python3 -c '
import os
import sys

rendered = sys.stdin.read()
for name in ("NOMAD_SERVER_IP", "NOMAD_ADVERTISE_ADDR"):
    rendered = rendered.replace("${" + name + "}", os.environ[name])
sys.stdout.write(rendered)
'
EOF
chmod +x "$flood_bin/envsubst"
cp "$fixture_bin/nomad" "$flood_bin/nomad"
ln -s "$(command -v bash)" "$flood_bin/bash"
ln -s "$(command -v python3)" "$flood_bin/python3"
flood_id=$(prepare_approved_directory "$flood_out")
RUN_RENDER_PATH="$flood_bin:/usr/bin:/bin" run_render output-flood env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$flood_out" \
    NOMAD_RENDER_APPROVED_ID="$flood_id" \
    python3 "$fixture_root/run-renderer-with-limits.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$flood_out"
if [ "$render_status" -ne 0 ] \
    && grep -Fqi 'output limit' "$fixture_root/output-flood.out" \
    && [ "$(wc -c < "$fixture_root/output-flood.out" | tr -d ' ')" -lt 65536 ] \
    && directory_is_empty "$flood_out"; then
    pass "stdout and stderr capture is bounded before publication"
else
    sed -n '1,20p' "$fixture_root/output-flood.out" | sed 's/^/    /' >&2
    fail "a tool exceeded the diagnostic output bound"
fi

info "the approved destination must be empty"
nonempty_out="$fixture_root/nonempty"
nonempty_id=$(prepare_approved_directory "$nonempty_out")
printf '%s\n' 'existing victim' > "$nonempty_out/victim"
nonempty_inode=$(inode_of "$nonempty_out/victim")
run_render nonempty env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$nonempty_out" \
    NOMAD_RENDER_APPROVED_ID="$nonempty_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$nonempty_out"
if [ "$render_status" -ne 0 ] \
    && [ ! -s "$effect_log" ] \
    && [ "$(cat "$nonempty_out/victim")" = 'existing victim' ] \
    && [ "$(inode_of "$nonempty_out/victim")" = "$nonempty_inode" ]; then
    pass "a nonempty destination stops before child processes and preserves its entry"
else
    sed 's/^/    /' "$fixture_root/nonempty.out" >&2
    fail "rendering used or changed a nonempty destination"
fi

info "the approved destination must have mode 0700"
wrong_mode_out="$fixture_root/wrong-mode"
wrong_mode_id=$(prepare_approved_directory "$wrong_mode_out")
chmod 750 "$wrong_mode_out"
run_render wrong-mode env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$wrong_mode_out" \
    NOMAD_RENDER_APPROVED_ID="$wrong_mode_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$wrong_mode_out"
if [ "$render_status" -ne 0 ] \
    && [ ! -s "$effect_log" ] \
    && directory_is_empty "$wrong_mode_out"; then
    pass "nonprivate destination metadata stops before child processes"
else
    sed 's/^/    /' "$fixture_root/wrong-mode.out" >&2
    fail "rendering accepted a destination without exact private mode"
fi

info "an envsubst child cannot weaken the bound output parent"
env_parent="$fixture_root/env-parent"
env_parent_out="$env_parent/rendered"
mkdir -m 700 "$env_parent"
env_parent_id=$(prepare_approved_directory "$env_parent_out")
run_render env-parent env \
    ODYSSEUS_TEST_ENVSUBST_MODE=change-parent-mode \
    ODYSSEUS_TEST_NOMAD_PARENT_PATH="$env_parent" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$env_parent_out" \
    NOMAD_RENDER_APPROVED_ID="$env_parent_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$env_parent_out"
if [ "$render_status" -ne 0 ] \
    && [ "$(mode_of "$env_parent")" = 770 ] \
    && directory_is_empty "$env_parent_out" \
    && [ "$(grep -c '^envsubst$' "$effect_log")" = 1 ] \
    && ! grep -q '^nomad ' "$effect_log" \
    && ! grep -Fq 'rendered and HCL-validated' "$fixture_root/env-parent.out"; then
    pass "parent metadata is revalidated immediately after an envsubst child"
else
    sed 's/^/    /' "$fixture_root/env-parent.out" >&2
    fail "envsubst parent-metadata drift reached another child or publication"
fi

info "HCL-shaped address injection is rejected before parser effects"
injection_out="$fixture_root/injection"
injection_id=$(prepare_approved_directory "$injection_out")
hostile_ip=$'192.0.2.10:4647"]\nplugin "raw_exec" {\n  config { enabled = true }\n}\n#'
run_render injection env \
    NOMAD_SERVER_IP="$hostile_ip" NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$injection_out" \
    NOMAD_RENDER_APPROVED_ID="$injection_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$injection_out"
if [ "$render_status" -ne 0 ] \
    && [ ! -s "$effect_log" ] \
    && directory_is_empty "$injection_out"; then
    pass "only canonical literal IP addresses reach rendering or parsing"
else
    sed 's/^/    /' "$fixture_root/injection.out" >&2
    fail "an injected HCL fragment reached the parser or output"
fi

info "unbracketed IPv6 endpoint literals are rejected before parser effects"
ipv6_out="$fixture_root/ipv6"
ipv6_id=$(prepare_approved_directory "$ipv6_out")
run_render ipv6 env \
    NOMAD_SERVER_IP=2001:db8::10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$ipv6_out" \
    NOMAD_RENDER_APPROVED_ID="$ipv6_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$ipv6_out"
if [ "$render_status" -ne 0 ] \
    && grep -Fq 'canonical IPv4' "$fixture_root/ipv6.out" \
    && [ ! -s "$effect_log" ] \
    && directory_is_empty "$ipv6_out"; then
    pass "only address literals compatible with current endpoint templates are accepted"
else
    sed 's/^/    /' "$fixture_root/ipv6.out" >&2
    fail "an unbracketed IPv6 endpoint reached parsing or publication"
fi

info "parser failure leaves the approved destination empty"
parser_failure_out="$fixture_root/parser-failure"
parser_failure_id=$(prepare_approved_directory "$parser_failure_out")
run_render parser-failure env \
    ODYSSEUS_TEST_NOMAD_MODE=fail \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$parser_failure_out" \
    NOMAD_RENDER_APPROVED_ID="$parser_failure_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$parser_failure_out"
if [ "$render_status" -ne 0 ] \
    && grep -q '^nomad fmt -check ' "$effect_log" \
    && directory_is_empty "$parser_failure_out"; then
    pass "failed HCL validation publishes no rendered destination"
else
    sed 's/^/    /' "$fixture_root/parser-failure.out" >&2
    fail "failed HCL validation left or reported rendered state"
fi

info "a parser child cannot weaken the bound output parent"
parser_parent="$fixture_root/parser-parent"
parser_parent_out="$parser_parent/rendered"
mkdir -m 700 "$parser_parent"
parser_parent_id=$(prepare_approved_directory "$parser_parent_out")
run_render parser-parent env \
    ODYSSEUS_TEST_NOMAD_MODE=change-parent-mode \
    ODYSSEUS_TEST_NOMAD_PARENT_PATH="$parser_parent" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$parser_parent_out" \
    NOMAD_RENDER_APPROVED_ID="$parser_parent_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$parser_parent_out"
if [ "$render_status" -ne 0 ] \
    && [ "$(mode_of "$parser_parent")" = 770 ] \
    && directory_is_empty "$parser_parent_out" \
    && [ "$(grep -c '^envsubst$' "$effect_log")" = 2 ] \
    && [ "$(grep -c '^nomad fmt -check -$' "$effect_log")" = 1 ] \
    && ! grep -Fq 'rendered and HCL-validated' "$fixture_root/parser-parent.out"; then
    pass "parent metadata is revalidated immediately after a parser child"
else
    sed 's/^/    /' "$fixture_root/parser-parent.out" >&2
    fail "parser parent-metadata drift reached another child or publication"
fi

info "parser-time output metadata changes stop publication"
mode_race_out="$fixture_root/mode-race"
mode_race_id=$(prepare_approved_directory "$mode_race_out")
run_render mode-race env \
    ODYSSEUS_TEST_NOMAD_MODE=change-output-mode \
    ODYSSEUS_TEST_NOMAD_RACE_TARGET="$mode_race_out" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$mode_race_out" \
    NOMAD_RENDER_APPROVED_ID="$mode_race_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$mode_race_out"
if [ "$render_status" -ne 0 ] \
    && directory_is_empty "$mode_race_out" \
    && [ "$(mode_of "$mode_race_out")" = 755 ]; then
    pass "a parser cannot weaken output-directory metadata before publication"
else
    sed 's/^/    /' "$fixture_root/mode-race.out" >&2
    fail "parser-time output metadata drift reached publication"
fi

info "validated render publishes both exact files"
success_out="$fixture_root/success"
success_id=$(prepare_approved_directory "$success_out")
expected_out="$fixture_root/expected-success"
mkdir "$expected_out"
sed 's/${NOMAD_SERVER_IP}/192.0.2.10/g' \
    "$ROOT/configs/nomad/client.hcl" > "$expected_out/client.hcl"
sed 's/${NOMAD_ADVERTISE_ADDR}/192.0.2.11/g' \
    "$ROOT/configs/nomad/server.hcl" > "$expected_out/server.hcl"
run_render success env \
    ODYSSEUS_TEST_NOMAD_MODE=ok \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$success_out" \
    NOMAD_RENDER_APPROVED_ID="$success_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$success_out"
if [ "$render_status" -eq 0 ] \
    && [ "$(find "$success_out" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 2 ] \
    && cmp -s "$expected_out/client.hcl" "$success_out/client.hcl" \
    && cmp -s "$expected_out/server.hcl" "$success_out/server.hcl" \
    && [ "$(mode_of "$success_out")" = 700 ] \
    && [ "$(mode_of "$success_out/client.hcl")" = 644 ] \
    && [ "$(mode_of "$success_out/server.hcl")" = 644 ] \
    && grep -q '^nomad fmt -check ' "$effect_log"; then
    pass "parser-validated render publishes the exact config pair"
else
    sed 's/^/    /' "$fixture_root/success.out" >&2
    fail "validated render did not publish the exact config pair"
fi

cat > "$fixture_root/inject-publication-signal.py" <<'PY'
import importlib.util
import os
import signal
import sys

module_path, source, output, signal_name = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
real_write = renderer.write_new_regular


def injected_write(directory, name, content):
    if name == "server.hcl":
        os.kill(os.getpid(), getattr(signal, "SIG" + signal_name))
        raise AssertionError("termination signal was not delivered")
    return real_write(directory, name, content)


renderer.write_new_regular = injected_write
sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
raise SystemExit(renderer.main())
PY

cat > "$fixture_root/inject-partial-write-signal.py" <<'PY'
import importlib.util
import os
import signal
import sys

module_path, source, output, signal_name = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
real_write_new = renderer.write_new_regular


def interrupted_write(directory, name, content):
    real_os_write = renderer.os.write
    signalled = False

    def write_one_byte(descriptor, pending):
        nonlocal signalled
        written = real_os_write(descriptor, pending[:1])
        if not signalled:
            signalled = True
            os.kill(os.getpid(), getattr(signal, "SIG" + signal_name))
        return written

    renderer.os.write = write_one_byte
    try:
        return real_write_new(directory, name, content)
    finally:
        renderer.os.write = real_os_write


renderer.write_new_regular = interrupted_write
sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
raise SystemExit(renderer.main())
PY

info "TERM and HUP after the first output byte remove the exact partial inode"
for signal_case in TERM:143 HUP:129; do
    signal_name=${signal_case%%:*}
    expected_status=${signal_case##*:}
    partial_signal_out="$fixture_root/partial-signal-$signal_name"
    partial_signal_id=$(prepare_approved_directory "$partial_signal_out")
    run_render "partial-signal-$signal_name" env \
        NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
        NOMAD_RENDER_APPROVED_DIR="$partial_signal_out" \
        NOMAD_RENDER_APPROVED_ID="$partial_signal_id" \
        python3 "$fixture_root/inject-partial-write-signal.py" \
          "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
          "$partial_signal_out" "$signal_name"
    if [ "$render_status" -eq "$expected_status" ] \
        && directory_is_empty "$partial_signal_out"; then
        pass "$signal_name is re-raised after partial-inode cleanup"
    else
        sed 's/^/    /' "$fixture_root/partial-signal-$signal_name.out" >&2
        fail "$signal_name left a partial rendered output inode"
    fi
done

info "TERM and HUP between pair writes roll back the exact owned file"
for signal_case in TERM:143 HUP:129; do
    signal_name=${signal_case%%:*}
    expected_status=${signal_case##*:}
    pair_signal_out="$fixture_root/pair-signal-$signal_name"
    pair_signal_id=$(prepare_approved_directory "$pair_signal_out")
    run_render "pair-signal-$signal_name" env \
        NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
        NOMAD_RENDER_APPROVED_DIR="$pair_signal_out" \
        NOMAD_RENDER_APPROVED_ID="$pair_signal_id" \
        python3 "$fixture_root/inject-publication-signal.py" \
          "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
          "$pair_signal_out" "$signal_name"
    if [ "$render_status" -eq "$expected_status" ] \
        && directory_is_empty "$pair_signal_out"; then
        pass "$signal_name is re-raised after exact pair-publication rollback"
    else
        sed 's/^/    /' "$fixture_root/pair-signal-$signal_name.out" >&2
        fail "$signal_name left a partial Nomad configuration pair"
    fi
done

cat > "$fixture_root/inject-completion-race.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, source, output, mode, receipt = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
real_read = renderer.read_bound_regular
real_completion = renderer.verify_completion_state
output_state = os.lstat(output)
triggered = False


def injected_read(directory, name):
    global triggered
    result = real_read(directory, name)
    directory_state = os.fstat(directory)
    is_output = (
        directory_state.st_dev == output_state.st_dev
        and directory_state.st_ino == output_state.st_ino
    )
    if (
        is_output
        and name == "server.hcl"
        and mode in {"extra", "file-mode", "directory-mode"}
        and not triggered
    ):
        triggered = True
        if mode == "extra":
            descriptor = os.open(
                "raced-extra",
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=directory,
            )
            try:
                os.write(descriptor, b"completion race victim\n")
                metadata = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            Path(receipt).write_text(f"{metadata.st_ino}\n")
        elif mode == "file-mode":
            os.chmod("client.hcl", 0o600, dir_fd=directory)
            metadata = os.stat("client.hcl", dir_fd=directory, follow_symlinks=False)
            Path(receipt).write_text(f"{metadata.st_ino}\n")
        elif mode == "directory-mode":
            os.fchmod(directory, 0o755)
            Path(receipt).write_text("triggered\n")
        else:
            raise RuntimeError("unsupported completion-race mode")
    return result


def injected_completion(*arguments):
    result = real_completion(*arguments)
    if mode == "completion-output":
        held = output + ".held"
        os.rename(output, held)
        os.mkdir(output, 0o700)
        victim = Path(output, "victim")
        victim.write_text("completion replacement victim\n")
        Path(receipt).write_text(f"{os.lstat(victim).st_ino}\n")
    return result


renderer.read_bound_regular = injected_read
renderer.verify_completion_state = injected_completion
sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
try:
    renderer.run()
except RuntimeError as error:
    print(f"EXPECTED: {error}", file=sys.stderr)
    raise SystemExit(23)
raise SystemExit("completion race unexpectedly succeeded")
PY

info "a final content-walk race cannot add an unverified output entry"
completion_extra_out="$fixture_root/completion-extra-out"
completion_extra_id=$(prepare_approved_directory "$completion_extra_out")
completion_extra_receipt="$fixture_root/completion-extra.inode"
run_render completion-extra env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$completion_extra_out" \
    NOMAD_RENDER_APPROVED_ID="$completion_extra_id" \
    python3 "$fixture_root/inject-completion-race.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$completion_extra_out" extra "$completion_extra_receipt"
if [ "$render_status" -eq 23 ] \
    && [ "$(cat "$completion_extra_out/raced-extra")" = 'completion race victim' ] \
    && [ "$(inode_of "$completion_extra_out/raced-extra")" = \
      "$(cat "$completion_extra_receipt")" ] \
    && grep -Fq 'entries changed after content verification' \
      "$fixture_root/completion-extra.out" \
    && ! grep -Fq 'rendered and HCL-validated' \
      "$fixture_root/completion-extra.out"; then
    pass "completion revalidation rejects and preserves an added entry"
else
    sed 's/^/    /' "$fixture_root/completion-extra.out" >&2
    fail "an entry added after the content walk received a success receipt"
fi

info "a final content-walk race cannot weaken output-file metadata"
completion_file_out="$fixture_root/completion-file-out"
completion_file_id=$(prepare_approved_directory "$completion_file_out")
completion_file_receipt="$fixture_root/completion-file.inode"
run_render completion-file env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$completion_file_out" \
    NOMAD_RENDER_APPROVED_ID="$completion_file_id" \
    python3 "$fixture_root/inject-completion-race.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$completion_file_out" file-mode "$completion_file_receipt"
if [ "$render_status" -eq 23 ] \
    && [ ! -e "$completion_file_out/client.hcl" ] \
    && [ ! -e "$completion_file_out/server.hcl" ] \
    && grep -Fq 'metadata changed after content verification' \
      "$fixture_root/completion-file.out" \
    && ! grep -Fq 'rendered and HCL-validated' \
      "$fixture_root/completion-file.out"; then
    pass "completion revalidation rolls back the exact changed output inode"
else
    sed 's/^/    /' "$fixture_root/completion-file.out" >&2
    fail "file metadata changed after the content walk received a success receipt"
fi

info "a final content-walk race cannot weaken output-directory metadata"
completion_dir_out="$fixture_root/completion-directory-out"
completion_dir_id=$(prepare_approved_directory "$completion_dir_out")
completion_dir_receipt="$fixture_root/completion-directory.triggered"
run_render completion-directory env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$completion_dir_out" \
    NOMAD_RENDER_APPROVED_ID="$completion_dir_id" \
    python3 "$fixture_root/inject-completion-race.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$completion_dir_out" directory-mode "$completion_dir_receipt"
if [ "$render_status" -eq 23 ] \
    && [ -s "$completion_dir_receipt" ] \
    && [ "$(mode_of "$completion_dir_out")" = 755 ] \
    && grep -Fq 'identity or private metadata does not match' \
      "$fixture_root/completion-directory.out" \
    && ! grep -Fq 'rendered and HCL-validated' \
      "$fixture_root/completion-directory.out"; then
    pass "completion revalidation rejects and preserves changed directory metadata"
else
    sed 's/^/    /' "$fixture_root/completion-directory.out" >&2
    fail "directory metadata changed after the content walk received a success receipt"
fi

info "a post-verification output replacement cannot receive a success receipt"
completion_parent="$fixture_root/completion-parent"
completion_output="$completion_parent/rendered"
completion_output_receipt="$fixture_root/completion-output.inode"
mkdir -m 700 "$completion_parent"
completion_output_id=$(prepare_approved_directory "$completion_output")
run_render completion-output env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$completion_output" \
    NOMAD_RENDER_APPROVED_ID="$completion_output_id" \
    python3 "$fixture_root/inject-completion-race.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$completion_output" completion-output "$completion_output_receipt"
if [ "$render_status" -eq 23 ] \
    && [ "$(cat "$completion_output/victim")" = 'completion replacement victim' ] \
    && [ "$(inode_of "$completion_output/victim")" = \
      "$(cat "$completion_output_receipt")" ] \
    && [ ! -e "$completion_output.held/client.hcl" ] \
    && [ ! -e "$completion_output.held/server.hcl" ] \
    && grep -Fq 'output parent changed after final-state verification' \
      "$fixture_root/completion-output.out" \
    && ! grep -Fq 'rendered and HCL-validated' \
      "$fixture_root/completion-output.out"; then
    pass "completion revalidation rejects and preserves an output replacement"
else
    sed 's/^/    /' "$fixture_root/completion-output.out" >&2
    fail "a post-verification output replacement received a success receipt"
fi

info "a directory entry planted by the parser cannot capture publication"
directory_race_out="$fixture_root/directory-race"
directory_race_id=$(prepare_approved_directory "$directory_race_out")
directory_victim_inode="$fixture_root/directory-victim.inode"
directory_race_once="$fixture_root/directory-race.once"
run_render directory-race env \
    ODYSSEUS_TEST_NOMAD_MODE=plant-directory \
    ODYSSEUS_TEST_NOMAD_ONCE="$directory_race_once" \
    ODYSSEUS_TEST_NOMAD_RACE_TARGET="$directory_race_out" \
    ODYSSEUS_TEST_NOMAD_VICTIM_INODE="$directory_victim_inode" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$directory_race_out" \
    NOMAD_RENDER_APPROVED_ID="$directory_race_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$directory_race_out"
if [ "$render_status" -ne 0 ] \
    && [ "$(cat "$directory_race_out/victim")" = 'destination victim' ] \
    && [ "$(inode_of "$directory_race_out/victim")" = \
      "$(cat "$directory_victim_inode")" ] \
    && [ ! -e "$directory_race_out/client.hcl" ] \
    && [ ! -e "$directory_race_out/server.hcl" ]; then
    pass "exclusive publication preserves an entry planted by the parser"
else
    sed 's/^/    /' "$fixture_root/directory-race.out" >&2
    fail "a parser-planted entry captured a false-success render"
fi

info "a pre-open destination replacement cannot capture publication"
symlink_race_out="$fixture_root/symlink-race"
symlink_intended="$fixture_root/symlink-race-intended"
external_dir="$fixture_root/external-directory"
mkdir -m 700 "$symlink_intended" "$external_dir"
symlink_intended_id=$(identity_of "$symlink_intended")
printf '%s\n' 'external victim' > "$external_dir/victim"
external_inode=$(inode_of "$external_dir/victim")
mv "$symlink_intended" "$symlink_race_out.held"
ln -s "$external_dir" "$symlink_race_out"
run_render symlink-race env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$symlink_race_out" \
    NOMAD_RENDER_APPROVED_ID="$symlink_intended_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$symlink_race_out"
if [ "$render_status" -ne 0 ] \
    && [ -L "$symlink_race_out" ] \
    && [ "$(cat "$external_dir/victim")" = 'external victim' ] \
    && [ "$(inode_of "$external_dir/victim")" = "$external_inode" ] \
    && [ ! -e "$external_dir/client.hcl" ] \
    && [ ! -e "$external_dir/server.hcl" ]; then
    pass "approved identity prevents a replacement symlink from capturing writes"
else
    sed 's/^/    /' "$fixture_root/symlink-race.out" >&2
    fail "a raced symlink redirected rendered output"
fi

info "an output-parent swap cannot redirect publication or cleanup"
ancestor_parent="$fixture_root/ancestor-parent"
ancestor_displaced="$fixture_root/ancestor-parent.displaced"
ancestor_out="$ancestor_parent/rendered"
ancestor_victim_inode="$fixture_root/ancestor-victim.inode"
ancestor_once="$fixture_root/ancestor-race.once"
mkdir "$ancestor_parent"
ancestor_id=$(prepare_approved_directory "$ancestor_out")
run_render ancestor-race env \
    ODYSSEUS_TEST_NOMAD_MODE=swap-ancestor \
    ODYSSEUS_TEST_NOMAD_ONCE="$ancestor_once" \
    ODYSSEUS_TEST_NOMAD_PARENT_PATH="$ancestor_parent" \
    ODYSSEUS_TEST_NOMAD_RACE_TARGET="$ancestor_out" \
    ODYSSEUS_TEST_NOMAD_DISPLACED_PARENT="$ancestor_displaced" \
    ODYSSEUS_TEST_NOMAD_VICTIM_INODE="$ancestor_victim_inode" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$ancestor_out" \
    NOMAD_RENDER_APPROVED_ID="$ancestor_id" \
    "$JUST_BIN" --justfile "$ROOT/justfile" render-nomad-configs "$ancestor_out"
if [ "$render_status" -ne 0 ] \
    && [ "$(cat "$ancestor_out/victim")" = 'replacement-parent victim' ] \
    && [ "$(inode_of "$ancestor_out/victim")" = \
      "$(cat "$ancestor_victim_inode")" ] \
    && [ ! -e "$ancestor_out/client.hcl" ] \
    && [ ! -e "$ancestor_out/server.hcl" ]; then
    pass "descriptor-bound publication preserves replacement ancestors"
else
    sed 's/^/    /' "$fixture_root/ancestor-race.out" >&2
    fail "an ancestor swap redirected Nomad publication or cleanup"
fi

info "the parser receives bound bytes when a source pathname is swapped and restored"
swap_source="$fixture_root/swap-source"
swap_expected="$fixture_root/swap-expected"
swap_received="$fixture_root/swap-received"
swap_out="$fixture_root/swap-source-out"
swap_count="$fixture_root/swap-count"
mkdir "$swap_source" "$swap_expected" "$swap_received"
swap_out_id=$(prepare_approved_directory "$swap_out")
cp "$ROOT/configs/nomad/client.hcl" "$ROOT/configs/nomad/server.hcl" "$swap_source/"
sed 's/${NOMAD_SERVER_IP}/192.0.2.10/g' \
    "$swap_source/client.hcl" > "$swap_expected/client.hcl"
sed 's/${NOMAD_ADVERTISE_ADDR}/192.0.2.11/g' \
    "$swap_source/server.hcl" > "$swap_expected/server.hcl"
printf '%s\n' 1 > "$swap_count"
swap_client_inode=$(inode_of "$swap_source/client.hcl")
swap_server_inode=$(inode_of "$swap_source/server.hcl")
run_render swap-source env \
    ODYSSEUS_TEST_NOMAD_MODE=swap-source-restore \
    ODYSSEUS_TEST_NOMAD_COUNT="$swap_count" \
    ODYSSEUS_TEST_NOMAD_SOURCE_DIR="$swap_source" \
    ODYSSEUS_TEST_NOMAD_RECEIVED_DIR="$swap_received" \
    ODYSSEUS_TEST_NOMAD_EXPECTED_DIR="$swap_expected" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$swap_out" \
    NOMAD_RENDER_APPROVED_ID="$swap_out_id" \
    python3 "$ROOT/scripts/render_nomad_configs.py" \
      --source-dir "$swap_source" --output-dir "$swap_out"
if [ "$render_status" -ne 0 ] \
    && grep -Fq 'source changed during validation' \
      "$fixture_root/swap-source.out" \
    && [ "$(inode_of "$swap_source/client.hcl")" = "$swap_client_inode" ] \
    && [ "$(inode_of "$swap_source/server.hcl")" = "$swap_server_inode" ] \
    && cmp -s "$swap_received/client.hcl" "$swap_expected/client.hcl" \
    && cmp -s "$swap_received/server.hcl" "$swap_expected/server.hcl" \
    && directory_is_empty "$swap_out"; then
    pass "parser sees bound bytes and a restored source-path swap still fails closed"
else
    sed 's/^/    /' "$fixture_root/swap-source.out" >&2
    fail "a parser-time source swap changed the validated bytes"
fi

info "a source mutation during parser validation withholds publication"
mutation_source="$fixture_root/mutation-source"
mutation_out="$fixture_root/mutation-out"
mutation_once="$mutation_source/.mutation-once"
mkdir "$mutation_source"
mutation_out_id=$(prepare_approved_directory "$mutation_out")
cp "$ROOT/configs/nomad/client.hcl" "$ROOT/configs/nomad/server.hcl" \
    "$mutation_source/"
run_render source-mutation env \
    ODYSSEUS_TEST_NOMAD_MODE=mutate-source \
    ODYSSEUS_TEST_NOMAD_ONCE="$mutation_once" \
    ODYSSEUS_TEST_NOMAD_SOURCE_FILE="$mutation_source/client.hcl" \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$mutation_out" \
    NOMAD_RENDER_APPROVED_ID="$mutation_out_id" \
    python3 "$ROOT/scripts/render_nomad_configs.py" \
      --source-dir "$mutation_source" --output-dir "$mutation_out"
if [ "$render_status" -ne 0 ] \
    && grep -Fq 'source changed during validation' \
      "$fixture_root/source-mutation.out" \
    && directory_is_empty "$mutation_out"; then
    pass "source bytes remain bound through parser validation"
else
    sed 's/^/    /' "$fixture_root/source-mutation.out" >&2
    fail "parser-time source mutation produced a published result"
fi

cat > "$fixture_root/inject-publication-failure.py" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

module_path, source, output, mode, victim = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nomad_renderer", module_path)
assert spec is not None and spec.loader is not None
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
real_write = renderer.write_new_regular


def injected_write(directory, name, content):
    if name == "server.hcl":
        if mode == "leaf":
            os.link(victim, name, dst_dir_fd=directory, follow_symlinks=False)
        elif mode == "directory":
            held = output + ".held"
            os.rename(output, held)
            os.mkdir(output, 0o700)
            victim_file = Path(output, "victim")
            victim_file.write_text("replacement directory victim\n")
            Path(victim).write_text(f"{os.lstat(victim_file).st_ino}\n")
        else:
            raise RuntimeError("unsupported injected publication mode")
        raise RuntimeError("injected publication failure")
    return real_write(directory, name, content)


renderer.write_new_regular = injected_write
sys.argv = [module_path, "--source-dir", source, "--output-dir", output]
try:
    renderer.run()
except RuntimeError as error:
    if str(error) != "injected publication failure":
        raise
    raise SystemExit(23)
raise SystemExit("injected publication failure unexpectedly succeeded")
PY

info "a raced cleanup file leaf is retained without deleting its victim"
cleanup_leaf_out="$fixture_root/cleanup-leaf-out"
cleanup_leaf_id=$(prepare_approved_directory "$cleanup_leaf_out")
cleanup_leaf_victim="$fixture_root/cleanup-leaf-victim"
printf '%s\n' 'cleanup file victim' > "$cleanup_leaf_victim"
cleanup_leaf_inode=$(inode_of "$cleanup_leaf_victim")
run_render cleanup-leaf env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$cleanup_leaf_out" \
    NOMAD_RENDER_APPROVED_ID="$cleanup_leaf_id" \
    python3 "$fixture_root/inject-publication-failure.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$cleanup_leaf_out" leaf "$cleanup_leaf_victim"
if [ "$render_status" -eq 23 ] \
    && [ "$(cat "$cleanup_leaf_victim")" = 'cleanup file victim' ] \
    && [ "$(inode_of "$cleanup_leaf_victim")" = "$cleanup_leaf_inode" ] \
    && [ "$cleanup_leaf_out/server.hcl" -ef "$cleanup_leaf_victim" ] \
    && grep -Fq 'retained' "$fixture_root/cleanup-leaf.out"; then
    pass "failed publication retains a raced file leaf and its victim inode"
else
    sed 's/^/    /' "$fixture_root/cleanup-leaf.out" >&2
    fail "failure cleanup deleted or changed a raced file victim"
fi

info "a raced cleanup directory leaf is retained without deleting its victim"
cleanup_dir_out="$fixture_root/cleanup-directory-out"
cleanup_dir_id=$(prepare_approved_directory "$cleanup_dir_out")
cleanup_dir_victim="$cleanup_dir_out/victim"
cleanup_dir_inode_receipt="$fixture_root/cleanup-directory-victim.inode"
run_render cleanup-directory env \
    NOMAD_SERVER_IP=192.0.2.10 NOMAD_ADVERTISE_ADDR=192.0.2.11 \
    NOMAD_RENDER_APPROVED_DIR="$cleanup_dir_out" \
    NOMAD_RENDER_APPROVED_ID="$cleanup_dir_id" \
    python3 "$fixture_root/inject-publication-failure.py" \
      "$ROOT/scripts/render_nomad_configs.py" "$ROOT/configs/nomad" \
      "$cleanup_dir_out" directory "$cleanup_dir_inode_receipt"
if [ "$render_status" -eq 23 ] \
    && [ "$(cat "$cleanup_dir_victim")" = 'replacement directory victim' ] \
    && [ "$(inode_of "$cleanup_dir_victim")" = \
      "$(cat "$cleanup_dir_inode_receipt")" ] \
    && [ ! -e "$cleanup_dir_out.held/client.hcl" ]; then
    pass "failed publication rolls back owned files and preserves replacement objects"
else
    sed 's/^/    /' "$fixture_root/cleanup-directory.out" >&2
    fail "failure cleanup removed or changed a raced directory victim"
fi

summary
exit_code
