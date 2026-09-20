#!/usr/bin/env bash
# Hermetic behavior checks for the read-only Code Quality probe.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
ROOT="${SCRIPT_DIR%/tests}"
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-code-quality.XXXXXX")" || exit 1
fixture_root="$(CDPATH='' cd -P -- "$fixture_root" && pwd -P)" || exit 1
fixture_repo="$fixture_root/repo"
fixture_bin="$fixture_root/bin"
hostile_bin="$fixture_root/hostile-bin"
gh_log="$fixture_root/gh.log"
fixture_probe="$fixture_repo/tools/probe-code-quality.sh"
fixture_runtime="$fixture_repo/scripts/safe_report_publish.py"
mkdir -p "$fixture_repo/scripts" "$fixture_repo/tools" "$fixture_bin" "$hostile_bin"
cp "$ROOT/scripts/safe_report_publish.py" "$fixture_repo/scripts/safe_report_publish.py"
cp "$ROOT/tools/probe-code-quality.sh" "$fixture_probe"
chmod 0644 "$fixture_repo/scripts/safe_report_publish.py"
cat > "$fixture_repo/.gitmodules" <<'EOF'
[submodule "control/Agamemnon"]
    path = control/Agamemnon
    url = https://github.com/HomericIntelligence/Agamemnon.git
EOF

# Build one test-only copy. It preserves the production command path and
# process boundary but binds the fake executable without a production runtime
# override. Short bounds apply only to this disposable artifact.
/usr/bin/python3 -I -S - \
    "$fixture_runtime" "$fixture_bin/gh" "$fixture_probe" "$fixture_root" <<'PY'
import pathlib
import sys

runtime_path = pathlib.Path(sys.argv[1])
gh_path = sys.argv[2]
probe_path = pathlib.Path(sys.argv[3])
fixture_root = pathlib.Path(sys.argv[4])
runtime = runtime_path.read_text(encoding="utf-8")
old_candidates = '''EXECUTABLE_CANDIDATES = {
    "gh": (
        "/usr/bin/gh",
        "/usr/local/bin/gh",
        "/opt/homebrew/bin/gh",
    ),
}
'''
new_candidates = f'''EXECUTABLE_CANDIDATES = {{
    "gh": ({gh_path!r},),
}}
'''
if runtime.count(old_candidates) != 1:
    raise SystemExit("test runtime candidate contract changed")
deadline_hook = "def operation_deadline(seconds):\n    try:\n"
if runtime.count(deadline_hook) != 1:
    raise SystemExit("test runtime environment-audit hook changed")
runtime_path.write_text(
    runtime.replace(old_candidates, new_candidates).replace(
        deadline_hook,
        "def operation_deadline(seconds):\n"
        "    forbidden = {\"HTTP_PROXY\", \"HTTPS_PROXY\", \"PYTHONPATH\", "
        "\"AWS_SECRET_ACCESS_KEY\", \"GH_TOKEN\", \"GITHUB_TOKEN\", "
        "\"ODYSSEUS_TEST_RUNTIME\", "
        "\"ODYSSEUS_TEST_REPO_ROOT\", \"ODYSSEUS_GH_BIN\"}\n"
        "    if forbidden & set(os.environ):\n"
        "        raise OSError(\"ambient environment reached helper Python\")\n"
        "    try:\n",
    ),
    encoding="utf-8",
)

probe = probe_path.read_text(encoding="utf-8")
platform_gate = '''case "$OSTYPE" in
  linux*) ;;
  *)
    printf 'error: Linux descendant containment is required for GitHub reads\\n' >&2
    exit 2
    ;;
esac
'''
if probe.count(platform_gate) != 1:
    raise SystemExit("test probe platform gate contract changed")
probe = probe.replace(platform_gate, ": # test copy exercises pre-command boundaries\n")
old_bounds = '''REMOTE_TIMEOUT_SECONDS=30
REMOTE_OUTPUT_BYTES=8388608
REMOTE_OPERATION_SECONDS=300
'''
new_bounds = '''REMOTE_TIMEOUT_SECONDS=1
REMOTE_OUTPUT_BYTES=4096
REMOTE_OPERATION_SECONDS=10
'''
if probe.count(old_bounds) != 1:
    raise SystemExit("test probe bound contract changed")
probe = probe.replace(old_bounds, new_bounds)
track_hook = "            leader = scope.track_root(process.pid)\n"
if probe.count(track_hook) != 1:
    raise SystemExit("test probe process-acquisition contract changed")
phase_path = fixture_root / "signal.phase"
marker_path = fixture_root / "signal.acquisition.ready"
signal_hook = f'''            signal_phase = ""
            try:
                signal_phase = Path({str(phase_path)!r}).read_text(encoding="ascii").strip()
            except FileNotFoundError:
                pass
            if signal_phase == "pre":
                Path({str(marker_path)!r}).write_text("pre", encoding="ascii")
                wait_deadline = time.monotonic() + 5
                while not ({{signal.SIGTERM, signal.SIGHUP}} & signal.sigpending()):
                    if time.monotonic() >= wait_deadline:
                        raise RuntimeError("pre-track signal did not arrive")
                    time.sleep(0.005)
            leader = scope.track_root(process.pid)
            if signal_phase == "post":
                Path({str(marker_path)!r}).write_text("post", encoding="ascii")
'''
probe_path.write_text(
    probe.replace(track_hook, signal_hook),
    encoding="utf-8",
)
(fixture_root / "replacement-runtime.py").write_text(
    "import pathlib\n"
    f"pathlib.Path({str(fixture_root / 'replacement.marker')!r})"
    ".write_text('replacement runtime executed\\n', encoding='utf-8')\n"
    "raise SystemExit(99)\n",
    encoding="utf-8",
)
PY

cleanup() {
  : > "$fixture_root/stubborn.stop"
  /bin/sleep 0.1
  rm -r -- "$fixture_root" || {
    printf 'error: failed to remove probe fixture\n' >&2
    return 1
  }
}
trap cleanup EXIT

printf '#!/usr/bin/env bash\nFIXTURE_ROOT=%q\n' "$fixture_root" > "$fixture_bin/gh"
cat >> "$fixture_bin/gh" <<'EOF'
set -uo pipefail
mode=$(<"$FIXTURE_ROOT/gh.mode")
printf '%s\n' "$*" >> "$FIXTURE_ROOT/gh.log"

if [ "$mode" = signal-tree ]; then
  phase=$(<"$FIXTURE_ROOT/signal.phase")
  /usr/bin/python3 -I -S - \
    "$FIXTURE_ROOT/signal.${phase}.identity" \
    "$FIXTURE_ROOT/signal.${phase}.heartbeat" <<'PY'
import os
import signal
import sys
import time
from pathlib import Path


def identity(process_id):
    content = Path(f"/proc/{process_id}/stat").read_bytes()
    closing = content.rfind(b")")
    return int(content[closing + 2 :].split()[19])


identity_path = Path(sys.argv[1])
heartbeat = Path(sys.argv[2])
child = os.fork()
if child == 0:
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass
    count = 0
    while True:
        heartbeat.write_text(str(count), encoding="ascii")
        count += 1
        time.sleep(0.01)

signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
identity_path.write_text(
    f"{os.getpid()} {identity(os.getpid())} {child} {identity(child)}",
    encoding="ascii",
)
for descriptor in (1, 2):
    try:
        os.close(descriptor)
    except OSError:
        pass
while True:
    time.sleep(1)
PY
  exit 99
fi

if [ "$mode" = env-audit ]; then
  [ "${HOME:-}" = /dev/null ] \
    && [ "${XDG_CONFIG_HOME:-}" = /dev/null ] \
    && [ "${GH_HOST:-}" = github.com ] \
    && [ "${GH_PROMPT_DISABLED:-}" = 1 ] \
    && [ -z "${HTTP_PROXY+x}" ] \
    && [ -z "${HTTPS_PROXY+x}" ] \
    && [ -z "${GIT_CONFIG+x}" ] \
    && [ -z "${PYTHONPATH+x}" ] \
    && [ -z "${ODYSSEUS_TEST_RUNTIME+x}" ] \
    && [ -z "${ODYSSEUS_TEST_REPO_ROOT+x}" ] \
    && [ -z "${ODYSSEUS_GH_BIN+x}" ] || exit 87
fi

endpoint=""
for argument in "$@"; do
  case "$argument" in
    repos/*|orgs/*) endpoint="$argument" ;;
  esac
done
[ -n "$endpoint" ] || exit 90

case "$endpoint" in
  orgs/HomericIntelligence/repos\?per_page=100\&type=all)
    case "$mode" in
      inventory-unavailable) exit 91 ;;
      inventory-unsafe) printf '%s\n' '[[{"name":"bad|repo"}]]' ;;
      inventory-duplicate) printf '%s\n' '[[{"name":"Alpha"},{"name":"Alpha"}]]' ;;
      *) printf '%s\n' '[[{"name":"Beta"},{"name":"Alpha"}]]' ;;
    esac
    ;;
  repos/HomericIntelligence/*/code-scanning/default-setup)
    case "$mode" in
      unavailable) exit 92 ;;
      scanning-invalid) printf '%s\n' '{"state":"configured|bad"}' ;;
      *) printf '%s\n' '{"state":"configured"}' ;;
    esac
    ;;
  repos/HomericIntelligence/*/code-quality)
    case "$mode" in
      unavailable) exit 92 ;;
      quality-multiple) printf '%s\n' '{"enabled":true}' '{"enabled":false}' ;;
      hang) /bin/sleep 20; printf '%s\n' '{"enabled":false}' ;;
      escaped-child)
        [ "${GH_TOKEN:-}" = odysseus-test-placeholder ] || exit 96
        /usr/bin/python3 -I -S -c '
import os
import sys
import time

heartbeat, stop, identity = sys.argv[1:]
first = os.fork()
if first:
    os.waitpid(first, 0)
    raise SystemExit(0)
os.setsid()

def fork_after_cleanup_starts(_number, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    ready_read, ready_write = os.pipe()
    second = os.fork()
    if second:
        os.close(ready_write)
        os.read(ready_read, 1)
        os._exit(0)
    os.close(ready_read)
    os.setsid()
    detached = os.fork()
    if detached:
        os._exit(0)
    os.setsid()
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass
    with open(f"/proc/{os.getpid()}/stat", "rb", buffering=0) as stream:
        stat_line = stream.read(65537)
    closing = stat_line.rfind(b")")
    start_time = int(stat_line[closing + 2 :].split()[19])
    with open(identity, "w", encoding="ascii") as stream:
        stream.write(f"{os.getpid()} {start_time}\n")
    count = 0
    with open(heartbeat, "w", encoding="ascii") as stream:
        stream.write(f"{count:020d}\n")
    os.write(ready_write, b"1")
    os.close(ready_write)
    while not os.path.exists(stop):
        count += 1
        with open(heartbeat, "w", encoding="ascii") as stream:
            stream.write(f"{count:020d}\n")
        time.sleep(0.01)
    os._exit(0)

import signal
signal.signal(signal.SIGTERM, fork_after_cleanup_starts)
while True:
    signal.pause()
        ' "$FIXTURE_ROOT/stubborn.heartbeat" "$FIXTURE_ROOT/stubborn.stop" \
          "$FIXTURE_ROOT/stubborn.identity"
        ;;
      *) printf '%s\n' '{"enabled":false}' ;;
    esac
    ;;
  repos/HomericIntelligence/*/contents/*)
    [ "$mode" != unavailable ] || exit 92
    printf '%s\n' '{}'
    ;;
  repos/HomericIntelligence/*)
    if [ "$mode" = unavailable ]; then
      exit 92
    fi
    if [ "$mode" = flood ]; then
      /usr/bin/python3 -I -S -c 'import sys; sys.stdout.write("x" * 16384)'
      exit 0
    fi
    if [ "$mode" = swap-runtime ] \
        && [ ! -e "$FIXTURE_ROOT/swap.flag" ]; then
      : > "$FIXTURE_ROOT/swap.flag"
      mv "$FIXTURE_ROOT/repo/scripts/safe_report_publish.py" \
        "$FIXTURE_ROOT/repo/scripts/safe_report_publish.original"
      cp "$FIXTURE_ROOT/replacement-runtime.py" \
        "$FIXTURE_ROOT/repo/scripts/safe_report_publish.py"
      chmod 0644 "$FIXTURE_ROOT/repo/scripts/safe_report_publish.py"
    fi
    case "$mode" in
      feature-conflict)
        printf '%s\n' '{"security_and_analysis":{"dependabot_security_updates":{"enabled":true,"status":"disabled"},"secret_scanning":{"enabled":false},"secret_scanning_push_protection":{"enabled":true}}}'
        ;;
      feature-invalid-enabled)
        printf '%s\n' '{"security_and_analysis":{"dependabot_security_updates":{"enabled":"true","status":"enabled"},"secret_scanning":{"enabled":false},"secret_scanning_push_protection":{"enabled":true}}}'
        ;;
      feature-invalid-status)
        printf '%s\n' '{"security_and_analysis":{"dependabot_security_updates":{"enabled":true,"status":"pending"},"secret_scanning":{"enabled":false},"secret_scanning_push_protection":{"enabled":true}}}'
        ;;
      *)
        printf '%s\n' '{"security_and_analysis":{"dependabot_security_updates":{"enabled":true},"secret_scanning":{"enabled":false},"secret_scanning_push_protection":{"enabled":true}}}'
        ;;
    esac
    ;;
  *) exit 93 ;;
esac
EOF
chmod +x "$fixture_bin/gh"

for tool in gh git jq; do
  cat > "$hostile_bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "hostile tool ran: $0" >> "${ODYSSEUS_TEST_HOSTILE_MARKER:?}"
exit 97
EOF
  chmod +x "$hostile_bin/$tool"
done

run_probe() {
  local mode="$1"
  shift
  : > "$gh_log"
  printf '%s\n' "$mode" > "$fixture_root/gh.mode"
  set +e
  GH_TOKEN=odysseus-test-placeholder \
  ODYSSEUS_TEST_HOSTILE_MARKER="${ODYSSEUS_TEST_HOSTILE_MARKER:-}" \
  PATH="${ODYSSEUS_TEST_PATH:-$fixture_bin:/usr/bin:/bin}" \
    /usr/bin/env -u BASH_ENV -u ENV \
      /bin/bash --noprofile --norc -p "$fixture_probe" "$@" \
    > "$fixture_root/stdout" 2> "$fixture_root/stderr"
  probe_status=$?
  set -e
}

info "production probe ignores ambient test authority"
hostile_repo="$fixture_root/hostile-repo"
hostile_runtime_marker="$fixture_root/hostile-runtime-ran"
mkdir -p "$hostile_repo/scripts"
cat > "$hostile_repo/scripts/safe_report_publish.py" <<'PY'
import os
import pathlib

pathlib.Path(os.environ["PROBE_HOSTILE_RUNTIME_MARKER"]).write_text(
    "hostile runtime executed\n",
    encoding="utf-8",
)
raise SystemExit(91)
PY
chmod 0644 "$hostile_repo/scripts/safe_report_publish.py"
printf '%s\n' readback > "$fixture_root/gh.mode"
set +e
PROBE_HOSTILE_RUNTIME_MARKER="$hostile_runtime_marker" \
ODYSSEUS_TEST_RUNTIME=1 \
ODYSSEUS_TEST_REPO_ROOT="$hostile_repo" \
ODYSSEUS_GH_BIN="$hostile_bin/gh" \
  /usr/bin/env -u BASH_ENV -u ENV \
    /bin/bash --noprofile --norc -p "$fixture_probe" \
    > "$fixture_root/stdout" 2> "$fixture_root/stderr"
ambient_authority_status=$?
set -e
if [ ! -e "$hostile_runtime_marker" ] \
    && { [ "$(uname -s)" != Linux ] || [ "$ambient_authority_status" -eq 0 ]; }; then
  pass "ambient test variables cannot select runtime or executable authority"
else
  fail "ambient test variables redirected the production probe"
fi

run_probe readback
if [ "$probe_status" -eq 0 ] \
    && ! grep -Fq 'ambient environment reached helper Python' "$fixture_root/stderr"; then
  pass "credential values are withheld from non-GitHub helper Python"
else
  fail "a non-GitHub helper inherited credential authority"
fi

info "fixed probe callers scrub shell startup before Bash"
startup_env="$fixture_root/bash-env"
startup_marker="$fixture_root/bash-env-ran"
function_marker="$fixture_root/bash-function-ran"
xtrace_marker="$fixture_root/bash-xtrace.log"
printf 'printf "BASH_ENV executed\\n" > %q\n' "$startup_marker" > "$startup_env"
BASH_ENV="$startup_env" /bin/bash --noprofile --norc -c ':'
canary_is_sensitive=false
if [ -e "$startup_marker" ]; then canary_is_sensitive=true; fi
rm -f -- "$startup_marker"
unset() {
  /usr/bin/printf '%s\n' "${GH_TOKEN:-missing}" \
    > "${ODYSSEUS_TEST_SHELL_MARKER:?}"
  builtin unset "$@"
}
export -f unset
set +e
GH_TOKEN=odysseus-shell-secret \
ODYSSEUS_TEST_SHELL_MARKER="$function_marker" \
BASH_ENV="$startup_env" /usr/bin/env -u BASH_ENV -u ENV \
  /bin/bash --noprofile --norc -p "$fixture_probe" --help \
  > "$fixture_root/stdout" 2> "$fixture_root/stderr"
startup_status=$?
set -e
builtin unset -f unset
set +e
(
  exec 9> "$xtrace_marker"
  GH_TOKEN=odysseus-shell-secret \
  PS4='+${GH_TOKEN}: ' \
  BASH_XTRACEFD=9 \
  /usr/bin/env -u BASH_ENV -u ENV 'SHELLOPTS=xtrace' \
    /bin/bash --noprofile --norc -p "$fixture_probe" --help \
    > "$fixture_root/stdout" 2> "$fixture_root/stderr"
)
xtrace_status=$?
set -e
if [ "$canary_is_sensitive" = true ] \
    && [ "$startup_status" -eq 0 ] \
    && [ "$xtrace_status" -eq 0 ] \
    && [ ! -e "$startup_marker" ] \
    && [ ! -e "$function_marker" ] \
    && [ ! -s "$xtrace_marker" ]; then
  pass "the privileged launcher rejects Bash startup code and options"
else
  fail "the probe caller exposed ambient Bash startup authority"
fi

recipe_contract=$(just --dump --dump-format json \
  | /usr/bin/python3 -I -S -c '
import json
import sys

document = json.load(sys.stdin)
expected = {
    "script": {
        "command": "/usr/bin/env",
        "arguments": [
            "-u", "BASH_ENV", "-u", "ENV",
            "/bin/bash", "--noprofile", "--norc", "-p",
        ],
    },
}
for name in ("code-quality-audit", "code-quality-audit-all", "code-quality-update"):
    recipe = document["recipes"][name]
    if recipe["attributes"] != [expected] or recipe["shebang"] is not True:
        raise SystemExit(1)
update = "\n".join(line[0] for line in document["recipes"]["code-quality-update"]["body"])
if (
    "/usr/bin/mktemp -d /tmp/odysseus-code-quality." not in update
    or "docs/ecosystem-code-quality-status.md" in update
    or "/bin/bash --noprofile --norc -p" not in update
):
    raise SystemExit(1)
print("bound")
') || recipe_contract=""
if [ "$recipe_contract" = bound ]; then
  pass "just recipes use the fixed launcher and an absent private report target"
else
  fail "just recipes expose shell startup or an unusable existing report target"
fi

linux_process_identity_is_active() {
  /usr/bin/python3 -I -S - "$1" "$2" <<'PY'
import sys

process_id = int(sys.argv[1])
expected_start_time = int(sys.argv[2])
try:
    with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
        content = stream.read(65537)
except (FileNotFoundError, ProcessLookupError):
    raise SystemExit(1)
closing = content.rfind(b")")
if closing < 1:
    raise SystemExit(2)
fields = content[closing + 2 :].split()
if len(fields) <= 19:
    raise SystemExit(2)
raise SystemExit(0 if int(fields[19]) == expected_start_time else 1)
PY
}

if [ "$(uname -s)" = Linux ]; then
  info "explicit readbacks round-trip without jq or Git subprocesses"
  hostile_marker="$fixture_root/hostile-tools.log"
  ODYSSEUS_TEST_PATH="$hostile_bin:/usr/bin:/bin" \
  ODYSSEUS_TEST_HOSTILE_MARKER="$hostile_marker" run_probe readback
  if [ "$probe_status" -eq 0 ] \
      && grep -Fq '| Odysseus | enabled | disabled | enabled | configured | disabled | present |' "$fixture_root/stdout" \
      && grep -Fq '| Agamemnon | enabled | disabled | enabled | configured | disabled | present |' "$fixture_root/stdout" \
      && [ ! -e "$hostile_marker" ]; then
    pass "the probe uses validated JSON and the explicitly bound GitHub executable"
  else
    fail "explicit readbacks selected an ambient tool or changed state"
  fi

  info "failed remote reads stay explicitly unavailable"
  run_probe unavailable
  if [ "$probe_status" -eq 0 ] \
      && grep -Fq '| Odysseus | unavailable | unavailable | unavailable | unavailable | unavailable | unavailable |' "$fixture_root/stdout"; then
    pass "transport failure is visible without inventing a setting"
  else
    fail "failed remote reads became concrete state or aborted the audit"
  fi

  info "GitHub subprocesses receive only the explicit credential boundary"
  HTTP_PROXY=http://proxy.invalid \
  HTTPS_PROXY=http://proxy.invalid \
  GIT_CONFIG="$fixture_root/hostile-git-config" \
  PYTHONPATH="$fixture_root/hostile-python" \
    run_probe env-audit
  if [ "$probe_status" -eq 0 ] \
      && grep -Fq '| Odysseus | enabled | disabled | enabled | configured | disabled | present |' "$fixture_root/stdout"; then
    pass "ambient proxy, Git, Python, HOME, and host settings are scrubbed"
  else
    fail "ambient process state reached the GitHub subprocess"
  fi
fi

info "a verified GitHub executable stays bound through process creation"
gh_original="$fixture_root/gh-bound-original"
gh_replacement_marker="$fixture_root/gh-replacement-ran"
: > "$gh_log"
set +e
GH_TOKEN=odysseus-test-placeholder \
  /usr/bin/python3 -I -S - \
    "$fixture_runtime" \
    "$fixture_bin/gh" \
    "$gh_original" \
    "$gh_replacement_marker" <<'PY'
import importlib.util
import os
import shlex
import stat
import sys

publisher_path, executable_path, original_path, replacement_marker = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "safe_report_publish_executable_probe",
    publisher_path,
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

binding = publisher.resolve_executable("gh", "")
real_popen = publisher.subprocess.Popen


def swapping_popen(*args, **kwargs):
    os.replace(executable_path, original_path)
    descriptor = os.open(
        executable_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o700,
    )
    try:
        content = (
            "#!/bin/bash\n"
            f"printf 'replacement executed\\n' > {shlex.quote(replacement_marker)}\n"
            "exit 99\n"
        ).encode("utf-8")
        while content:
            written = os.write(descriptor, content)
            if written <= 0:
                raise OSError("replacement write made no progress")
            content = content[written:]
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    finally:
        os.close(descriptor)
    return real_popen(*args, **kwargs)


publisher.subprocess.Popen = swapping_popen
try:
    publisher.run_trusted_command(
        "gh",
        str(publisher.operation_deadline("10")),
        "5",
        "4096",
        binding,
        [
            "repo",
            "view",
            "HomericIntelligence/Atlas",
            "--json",
            "defaultBranchRef",
            "--jq",
            ".defaultBranchRef.name",
        ],
    )
except (NotImplementedError, OSError, SystemExit):
    pass
else:
    raise SystemExit("the changed executable name was reported as success")
PY
executable_swap_status=$?
set -e
if [ -e "$gh_original" ]; then
  /bin/rm -f -- "$fixture_bin/gh"
  /bin/mv -- "$gh_original" "$fixture_bin/gh"
fi
if [ "$(uname -s)" = Linux ]; then
  if [ "$executable_swap_status" -eq 0 ] \
      && [ ! -e "$gh_replacement_marker" ] \
      && grep -Fq 'repo view HomericIntelligence/Atlas' "$gh_log"; then
    pass "process creation executes sealed GitHub executable content"
  else
    fail "a pathname replacement controlled GitHub process creation"
  fi
elif [ "$executable_swap_status" -eq 0 ] \
    && [ ! -e "$gh_replacement_marker" ] \
    && [ ! -s "$gh_log" ]; then
  pass "platforms without immutable execution fail before process creation"
else
  fail "an unsupported platform reached GitHub process creation"
fi

if [ "$(uname -s)" = Linux ]; then
  info "same-inode mutation cannot change sealed Linux execution bytes"
  gh_same_inode_backup="$fixture_root/gh-same-inode-backup"
  gh_same_inode_marker="$fixture_root/gh-same-inode-ran"
  gh_seal_error_marker="$fixture_root/gh-seals-invalid"
  /bin/cp -p -- "$fixture_bin/gh" "$gh_same_inode_backup"
  : > "$gh_log"
  set +e
  GH_TOKEN=odysseus-test-placeholder \
    /usr/bin/python3 -I -S - \
      "$fixture_runtime" \
      "$fixture_bin/gh" \
      "$gh_seal_error_marker" \
      "$gh_same_inode_marker" <<'PY'
import fcntl
import importlib.util
import os
import shlex
import stat
import sys

publisher_path, executable_path, seal_error_marker, replacement_marker = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "safe_report_publish_same_inode_probe",
    publisher_path,
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
binding = publisher.resolve_executable("gh", "")
real_popen = publisher.subprocess.Popen


def mutating_popen(*args, **kwargs):
    launch_path = kwargs.get("executable", "")
    try:
        launch_descriptor = int(os.path.basename(launch_path))
        seals = fcntl.fcntl(launch_descriptor, fcntl.F_GET_SEALS)
        required = (
            fcntl.F_SEAL_WRITE
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_SEAL
        )
        if seals & required != required:
            raise OSError("required executable seals are absent")
    except (AttributeError, OSError, TypeError, ValueError):
        with open(seal_error_marker, "wb") as stream:
            stream.write(b"required executable seals are absent\n")
    descriptor = os.open(executable_path, os.O_WRONLY | os.O_TRUNC)
    try:
        replacement = (
            "#!/bin/bash\n"
            f"printf 'same inode replacement executed\\n' > {shlex.quote(replacement_marker)}\n"
            "exit 99\n"
        ).encode("utf-8")
        while replacement:
            written = os.write(descriptor, replacement)
            if written <= 0:
                raise OSError("same-inode replacement write made no progress")
            replacement = replacement[written:]
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    finally:
        os.close(descriptor)
    return real_popen(*args, **kwargs)


publisher.subprocess.Popen = mutating_popen
try:
    publisher.run_trusted_command(
        "gh",
        str(publisher.operation_deadline("10")),
        "5",
        "4096",
        binding,
        ["repo", "view", "HomericIntelligence/Atlas"],
    )
except (NotImplementedError, OSError, SystemExit):
    pass
else:
    raise SystemExit("same-inode executable mutation was reported as success")
PY
  same_inode_status=$?
  set -e
  /bin/rm -f -- "$fixture_bin/gh"
  /bin/mv -- "$gh_same_inode_backup" "$fixture_bin/gh"
  if [ "$same_inode_status" -eq 0 ] \
      && [ ! -e "$gh_same_inode_marker" ] \
      && [ ! -e "$gh_seal_error_marker" ] \
      && grep -Fq 'repo view HomericIntelligence/Atlas' "$gh_log"; then
    pass "all required kernel seals protect Linux execution bytes"
  else
    fail "same-inode mutation changed Linux execution bytes or seals"
  fi
fi

if [ "$(uname -s)" = Darwin ]; then
  info "Darwin fails before a mutable private snapshot reaches Popen"
  darwin_popen_marker="$fixture_root/darwin-popen-reached"
  darwin_replacement_marker="$fixture_root/darwin-replacement-ran"
  set +e
  GH_TOKEN=odysseus-test-placeholder \
    /usr/bin/python3 -I -S - \
      "$fixture_runtime" \
      "$fixture_bin/gh" \
      "$darwin_popen_marker" \
      "$darwin_replacement_marker" <<'PY'
import importlib.util
import os
import shlex
import stat
import sys

publisher_path, executable_path, popen_marker, replacement_marker = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "safe_report_publish_darwin_mutation_probe",
    publisher_path,
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
binding = publisher.resolve_executable("gh", "")
real_popen = publisher.subprocess.Popen


def mutating_popen(*args, **kwargs):
    with open(popen_marker, "wb") as stream:
        stream.write(b"Popen reached\n")
    launch_path = kwargs.get("executable", "")
    os.chmod(launch_path, stat.S_IRWXU)
    descriptor = os.open(launch_path, os.O_WRONLY | os.O_TRUNC)
    try:
        replacement = (
            "#!/bin/bash\n"
            f"printf 'Darwin replacement executed\\n' > {shlex.quote(replacement_marker)}\n"
            "exit 99\n"
        ).encode("utf-8")
        while replacement:
            written = os.write(descriptor, replacement)
            if written <= 0:
                raise OSError("Darwin replacement write made no progress")
            replacement = replacement[written:]
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IXUSR)
    finally:
        os.close(descriptor)
    return real_popen(*args, **kwargs)


publisher.subprocess.Popen = mutating_popen
try:
    publisher.run_trusted_command(
        "gh",
        str(publisher.operation_deadline("10")),
        "5",
        "4096",
        binding,
        ["repo", "view", "HomericIntelligence/Atlas"],
    )
except (NotImplementedError, OSError, SystemExit):
    pass
else:
    raise SystemExit("mutable Darwin snapshot execution was reported as success")
PY
  darwin_mutation_status=$?
  set -e
  if [ "$darwin_mutation_status" -eq 0 ] \
      && [ ! -e "$darwin_popen_marker" ] \
      && [ ! -e "$darwin_replacement_marker" ]; then
    pass "Darwin rejects command execution before Popen"
  else
    fail "mutable Darwin snapshot content reached process creation"
  fi
fi

info "unsupported or unsealed execution fails before process creation"
unsupported_launch_marker="$fixture_root/unsupported-launch-ran"
set +e
/usr/bin/python3 -I -S - \
    "$fixture_runtime" \
    "$fixture_bin/gh" \
    "$unsupported_launch_marker" <<'PY'
import importlib.util
import os
import sys

publisher_path, executable_path, launch_marker = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "safe_report_publish_platform_probe",
    publisher_path,
)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
binding = publisher.resolve_executable("gh", "")


def recording_popen(*_args, **_kwargs):
    with open(launch_marker, "wb") as stream:
        stream.write(b"process creation reached\n")
    raise RuntimeError("process creation must not run")


publisher.subprocess.Popen = recording_popen


def invoke(label):
    try:
        publisher.run_trusted_command(
            "gh",
            str(publisher.operation_deadline("10")),
            "5",
            "4096",
            binding,
            ["repo", "view", "HomericIntelligence/Atlas"],
        )
    except (NotImplementedError, OSError, RuntimeError, SystemExit):
        return
    raise SystemExit(f"{label} was accepted")


publisher.sys.platform = "unsupported-test-platform"
invoke("unsupported descriptor execution")

publisher.sys.platform = "linux"
publisher.os.memfd_create = None
invoke("execution without memfd sealing")


def unsealed_duplicate(source, _expected):
    size, digest = publisher.read_executable_digest(source)
    return os.dup(source), size, digest


real_stat = publisher.os.stat


def missing_descriptor_route(path, *args, **kwargs):
    if str(path).startswith("/proc/self/fd/"):
        raise FileNotFoundError("test-forced missing descriptor route")
    return real_stat(path, *args, **kwargs)


publisher.create_sealed_executable = unsealed_duplicate
publisher.os.stat = missing_descriptor_route
invoke("execution without a descriptor route")
if os.path.exists(launch_marker):
    raise SystemExit("unsupported or unsealed execution started a process")
PY
unsupported_launch_status=$?
set -e
if [ "$unsupported_launch_status" -eq 0 ] \
    && [ ! -e "$unsupported_launch_marker" ]; then
  pass "unsupported or unsealed execution fails closed"
else
  fail "unsupported or unsealed execution reached process creation"
fi

if [ "$(uname -s)" != Linux ]; then
  summary
  exit_code
  exit
fi

info "hostile state shapes cannot inject report cells"
for mode in scanning-invalid quality-multiple; do
  run_probe "$mode"
  if [ "$probe_status" -eq 0 ] \
      && grep -Fq '| unavailable |' "$fixture_root/stdout" \
      && ! grep -Fq 'configured|bad' "$fixture_root/stdout"; then
    pass "$mode remains unavailable"
  else
    fail "$mode escaped the documented state grammar"
  fi
done

info "contradictory or invalid feature states remain unavailable"
for mode in feature-conflict feature-invalid-enabled feature-invalid-status; do
  run_probe "$mode"
  if [ "$probe_status" -eq 0 ] \
      && grep -Fq '| Odysseus | unavailable | disabled | enabled | configured | disabled | present |' \
          "$fixture_root/stdout"; then
    pass "$mode remains unavailable"
  else
    fail "$mode became a concrete enabled or disabled state"
  fi
done

info "organization inventory is complete, paginated, validated, and unique"
run_probe readback --all
if [ "$probe_status" -eq 0 ] \
    && grep -Fq 'mode: organization inventory' "$fixture_root/stdout" \
    && grep -Fq '| Alpha |' "$fixture_root/stdout" \
    && grep -Fq '| Beta |' "$fixture_root/stdout" \
    && grep -Fq 'api --paginate --slurp orgs/HomericIntelligence/repos?per_page=100&type=all' "$gh_log"; then
  pass "all organization pages supply the live scope"
else
  fail "organization scope was incomplete or used a jq side channel"
fi
for mode in inventory-unavailable inventory-unsafe inventory-duplicate; do
  run_probe "$mode" --all
  if [ "$probe_status" -ne 0 ] && [ ! -s "$fixture_root/stdout" ]; then
    pass "$mode fails before a partial report"
  else
    fail "$mode produced a partial organization report"
  fi
done

info "remote output and time are bounded"
run_probe flood
if [ "$probe_status" -eq 0 ] \
    && grep -Fq 'output limit' "$fixture_root/stderr" \
    && grep -Fq '| Odysseus | unavailable | unavailable | unavailable |' "$fixture_root/stdout"; then
  pass "oversized responses become explicit unavailable readbacks"
else
  fail "an oversized response escaped the remote process boundary"
fi
SECONDS=0
run_probe hang
elapsed=$SECONDS
if [ "$probe_status" -eq 0 ] \
    && [ "$elapsed" -lt 10 ] \
    && grep -Fq 'timed out' "$fixture_root/stderr" \
    && grep -Eq '\| configured \| unavailable \| (present|unavailable) \|' \
        "$fixture_root/stdout"; then
  pass "a hanging read is terminated and marked unavailable"
else
  sed -n '1,120p' "$fixture_root/stderr" >&2
  fail "a hanging read outlived its deadline (${elapsed}s)"
fi

heartbeat="$fixture_root/stubborn.heartbeat"
stopfile="$fixture_root/stubborn.stop"
identity_file="$fixture_root/stubborn.identity"
heartbeat_snapshot="$fixture_root/stubborn.heartbeat.snapshot"
rm -f -- "$heartbeat" "$stopfile" "$identity_file" "$heartbeat_snapshot"
GH_TOKEN=odysseus-test-placeholder run_probe escaped-child
for _ in $(seq 1 40); do
  [ -s "$heartbeat" ] && [ -s "$identity_file" ] && break
  /bin/sleep 0.025
done
cp -- "$heartbeat" "$heartbeat_snapshot"
read -r escaped_pid escaped_start_time < "$identity_file"
/bin/sleep 0.25
heartbeat_is_stable=false
if cmp -s "$heartbeat_snapshot" "$heartbeat"; then
  heartbeat_is_stable=true
fi
identity_is_extinct=false
for _ in $(seq 1 40); do
  if ! linux_process_identity_is_active "$escaped_pid" "$escaped_start_time"; then
    identity_is_extinct=true
    break
  fi
  /bin/sleep 0.025
done
: > "$stopfile"
if [ "$probe_status" -eq 0 ] \
    && [ "$heartbeat_is_stable" = true ] \
    && [ "$identity_is_extinct" = true ] \
    && grep -Eq 'timed out|detached descendant' "$fixture_root/stderr"; then
  pass "containment extinguishes the exact double-forked setsid process identity"
else
  printf 'status=%s pid=%s start=%s stable=%s extinct=%s\n' \
    "$probe_status" "${escaped_pid:-missing}" \
    "${escaped_start_time:-missing}" "$heartbeat_is_stable" \
    "$identity_is_extinct" >&2
  fail "a double-forked setsid child survived after its leader exited"
fi

info "TERM and HUP cancellation extinguish the probe process tree"
setsid_path=""
if ! setsid_path=$(command -v setsid); then setsid_path=""; fi
if [ -z "$setsid_path" ]; then
  fail "setsid is unavailable for the cancellation boundary test"
else
  for signal_case in pre:TERM post:HUP; do
    phase=${signal_case%%:*}
    signal_name=${signal_case#*:}
    signal_phase="$fixture_root/signal.phase"
    signal_ready="$fixture_root/signal.acquisition.ready"
    signal_identity="$fixture_root/signal.${phase}.identity"
    signal_heartbeat="$fixture_root/signal.${phase}.heartbeat"
    signal_snapshot="$fixture_root/signal.${phase}.snapshot"
    rm -f -- "$signal_ready" "$signal_identity" "$signal_heartbeat" "$signal_snapshot"
    printf '%s\n' "$phase" > "$signal_phase"
    printf '%s\n' signal-tree > "$fixture_root/gh.mode"
    set +e
    GH_TOKEN=odysseus-test-placeholder \
      "$setsid_path" /bin/bash --noprofile --norc -p "$fixture_probe" \
      > "$fixture_root/stdout" 2> "$fixture_root/stderr" &
    probe_pid=$!
    set -e
    for _ in $(seq 1 400); do
      [ -s "$signal_ready" ] && [ -s "$signal_identity" ] \
        && [ -s "$signal_heartbeat" ] && break
      /bin/sleep 0.01
    done
    signal_status=255
    if [ -s "$signal_ready" ] && [ -s "$signal_identity" ] \
        && [ -s "$signal_heartbeat" ]; then
      read -r signal_parent signal_parent_start signal_child signal_child_start \
        < "$signal_identity"
      if ! /bin/kill -s "$signal_name" -- "-$probe_pid" 2>/dev/null; then :; fi
      set +e
      wait "$probe_pid"
      signal_status=$?
      set -e
      for _ in $(seq 1 200); do
        if ! linux_process_identity_is_active "$signal_parent" "$signal_parent_start" \
            && ! linux_process_identity_is_active "$signal_child" "$signal_child_start"; then
          break
        fi
        /bin/sleep 0.01
      done
      cp -- "$signal_heartbeat" "$signal_snapshot"
      /bin/sleep 0.2
      signal_stable=false
      if cmp -s "$signal_snapshot" "$signal_heartbeat"; then
        signal_stable=true
      fi
      signal_extinct=false
      if ! linux_process_identity_is_active "$signal_parent" "$signal_parent_start" \
          && ! linux_process_identity_is_active "$signal_child" "$signal_child_start"; then
        signal_extinct=true
      fi
      if ! /bin/kill -KILL "$signal_parent" "$signal_child" 2>/dev/null; then :; fi
    else
      signal_stable=false
      signal_extinct=false
      if ! /bin/kill -KILL -- "-$probe_pid" 2>/dev/null; then :; fi
      if ! wait "$probe_pid" 2>/dev/null; then :; fi
    fi
    if [ "$signal_status" -ne 0 ] \
        && [ "$signal_stable" = true ] \
        && [ "$signal_extinct" = true ]; then
      pass "$signal_name during $phase-track acquisition extinguishes the probe tree"
    else
      fail "$signal_name during $phase-track acquisition left probe work alive"
    fi
  done
fi

info "output publication uses the immutable runtime snapshot"
output="$fixture_root/report.md"
rm -f -- "$output"
replacement_marker="$fixture_root/replacement.marker"
runtime_original="$fixture_repo/scripts/safe_report_publish.original"
run_probe swap-runtime --output "$output"
if [ "$probe_status" -eq 0 ] \
    && [ ! -e "$replacement_marker" ] \
    && cmp -s "$output" "$fixture_root/stdout"; then
  pass "a pathname replacement cannot replace bound publication code"
else
  fail "a mutable runtime pathname controlled report publication"
fi
mv "$runtime_original" "$fixture_repo/scripts/safe_report_publish.py"

info "unsafe sinks fail before remote readback"
printf '%s\n' victim > "$fixture_root/victim"
ln -s "$fixture_root/victim" "$fixture_root/report-link.md"
run_probe readback --output "$fixture_root/report-link.md"
if [ "$probe_status" -ne 0 ] \
    && [ "$(cat "$fixture_root/victim")" = victim ] \
    && [ ! -s "$gh_log" ]; then
  pass "a symlink sink is rejected without network or mutation"
else
  fail "an unsafe sink was followed or checked after remote reads"
fi

summary
exit_code
