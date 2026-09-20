#!/usr/bin/env bash
# Hermetic behavior checks for exact-target AlexNet deploy, wait, and collect.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

# Exercise syscall-boundary race fixtures before the higher-level fleet cases.
# These Python checks are separate from the shell-case total below.
if ! python3 -I -E "$SCRIPT_DIR/test_alexnet_filesystem_races.py"; then
    echo "ERROR: AlexNet filesystem race fixtures failed" >&2
    exit 1
fi
real_python=$(command -v python3)
darwin_worker_fail_closed=0
if [ "$(uname -s)" = Darwin ]; then
    darwin_worker_fail_closed=1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-alexnet-operations.XXXXXX")"
fixture_root="$(cd "$(dirname "$fixture_root")" && pwd -P)/${fixture_root##*/}"
fixture_bin="$fixture_root/bin"
worker_swap_tmp=""
receipt_swap_tmp=""
mkdir -p "$fixture_bin"
cleanup_fixture() {
    if [ "${ODYSSEUS_KEEP_TEST_FIXTURE:-0}" = 1 ]; then
        echo "AlexNet operations fixture retained at: $fixture_root" >&2
        return
    fi
    if [ -n "$worker_swap_tmp" ] && [ -d "$worker_swap_tmp" ]; then
        rm -r -- "$worker_swap_tmp"
    fi
    if [ -n "$receipt_swap_tmp" ] && [ -d "$receipt_swap_tmp" ]; then
        rm -r -- "$receipt_swap_tmp"
    fi
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove AlexNet operations fixture: $fixture_root" >&2
    fi
}
trap cleanup_fixture EXIT

cat > "$fixture_bin/hostname" <<'EOF'
#!/usr/bin/env bash
if [ "${ODYSSEUS_TEST_REMOTE_CONTEXT:-0}" = 1 ] \
        && [ -n "${ODYSSEUS_TEST_RECEIPT_HOST:-}" ]; then
    printf '%s\n' "$ODYSSEUS_TEST_RECEIPT_HOST"
else
    printf '%s\n' hub
fi
EOF

cat > "$fixture_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >> "${ODYSSEUS_TEST_CALL_LOG:?}"
if [ "${ODYSSEUS_TEST_TAILSCALE_RC:-0}" != 0 ]; then
    exit "$ODYSSEUS_TEST_TAILSCALE_RC"
fi
if [ "${ODYSSEUS_TEST_TAILSCALE_JSON+x}" = x ]; then
    printf '%s\n' "$ODYSSEUS_TEST_TAILSCALE_JSON"
else
    printf '%s\n' '{"Peer":{}}'
fi
EOF

cat > "$fixture_bin/jq" <<'EOF'
#!/usr/bin/env bash
host=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --arg ] && [ "${2:-}" = h ]; then
        host="${3:-}"
        break
    fi
    shift
done
case "$host" in
    remote-one) printf '%s\n' 192.0.2.11 ;;
    remote-alias) printf '%s\n' 192.0.2.11 ;;
    remote-two) printf '%s\n' 192.0.2.12 ;;
    duplicate)
        printf '%s\n' 192.0.2.21 192.0.2.22
        ;;
    offline)
        case "$*" in
            *'.Online == true'*) exit 4 ;;
            *) printf '%s\n' 192.0.2.31 ;;
        esac
        ;;
    *) exit 4 ;;
esac
EOF

cat > "$fixture_bin/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "${ODYSSEUS_TEST_STUCK_LOG:-0}" = 1 ] \
        && [[ " $* " == *' podman logs '* ]]; then
    printf 'timeout %s\n' "$*" >> "${ODYSSEUS_TEST_CALL_LOG:?}"
    exit 124
fi
shift
exec "$@"
EOF

cat > "$fixture_bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "${ODYSSEUS_TEST_CALL_LOG:?}"
EOF

cat > "$fixture_bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ "${ODYSSEUS_TEST_CLOCK_MODE:-}" = near-deadline ]; then
    counter_file=${ODYSSEUS_TEST_CLOCK_COUNTER:?}
    counter=0
    if [ -f "$counter_file" ]; then
        counter=$(<"$counter_file")
    fi
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$counter_file"
    case "$counter" in
        1) printf '%s\n' 1000 ;;
        2) printf '%s\n' 9995 ;;
        *) printf '%s\n' 10000 ;;
    esac
    exit 0
fi
exec /bin/date "$@"
EOF

cat > "$fixture_bin/ls" <<'EOF'
#!/usr/bin/env bash
if [ "${*: -1}" = /tmp/odyssey-dev.tar ]; then
    exit 0
fi
exec /bin/ls "$@"
EOF

cat > "$fixture_bin/python3" <<'EOF'
#!/usr/bin/env bash
real_python=${ODYSSEUS_TEST_REAL_PYTHON:-/usr/bin/python3}
if [ "${ODYSSEUS_TEST_FAIL_HOLDER_SIGNAL:-0}" = 1 ] \
        && [[ " $* " == *pidfd_send_signal* ]]; then
    exit 77
fi
helper_action=${4:-}
if [ "${3:-}" = -c ]; then
    helper_action=${7:-${6:-}}
fi
if [ -n "${ODYSSEUS_TEST_HELPER_SWAP_SOURCE:-}" ] \
        && [ "$helper_action" = "${ODYSSEUS_TEST_HELPER_SWAP_ACTION:-}" ] \
        && [ ! -e "${ODYSSEUS_TEST_HELPER_SWAP_DONE:?}" ]; then
    /bin/mv -- "$ODYSSEUS_TEST_HELPER_SWAP_SOURCE" \
        "${ODYSSEUS_TEST_HELPER_SWAP_HELD:?}"
    printf '%s\n' \
        'import os' \
        'open(os.environ["ODYSSEUS_TEST_HELPER_SWAP_EXECUTED"], "w").write("executed\\n")' \
        'raise SystemExit(91)' \
        > "$ODYSSEUS_TEST_HELPER_SWAP_SOURCE"
    : > "$ODYSSEUS_TEST_HELPER_SWAP_DONE"
fi
if [ -n "${ODYSSEUS_TEST_HELPER_INPLACE_SOURCE:-}" ] \
        && [ "$helper_action" = "${ODYSSEUS_TEST_HELPER_INPLACE_ACTION:-}" ] \
        && [ ! -e "${ODYSSEUS_TEST_HELPER_INPLACE_DONE:?}" ]; then
    "$real_python" - "${ODYSSEUS_TEST_HELPER_INPLACE_SOURCE:?}" <<'PY'
import os
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    original = stream.read()
payload = (
    b"import os\n"
    b"open(os.environ['ODYSSEUS_TEST_HELPER_INPLACE_EXECUTED'], 'w').write('executed\\n')\n"
    b"raise SystemExit(91)\n"
)
if len(payload) > len(original):
    raise SystemExit("helper fixture is unexpectedly too small")
payload += b"#" * (len(original) - len(payload))
with open(path, "r+b", buffering=0) as stream:
    stream.write(payload)
    os.fsync(stream.fileno())
PY
    : > "$ODYSSEUS_TEST_HELPER_INPLACE_DONE"
fi
if [ "$helper_action" != train-publish-header ] \
        || [ "${ODYSSEUS_TEST_TRAIN_PUBLICATION_RACE:-0}" != 1 ]; then
    exec "$real_python" "$@"
fi
helper_output=$("$real_python" "$@") || exit $?
runs_root="${ODYSSEUS_TEST_TRAIN_RESULTS_ROOT:?}/runs"
/bin/mv -- "$runs_root" "${ODYSSEUS_TEST_TRAIN_HELD_ROOT:?}"
/bin/ln -s -- "${ODYSSEUS_TEST_TRAIN_VICTIM_ROOT:?}" "$runs_root"
printf '%s\n' "$helper_output"
EOF

cat > "$fixture_bin/ssh" <<'EOF'
#!/usr/bin/env bash
remote_host=""
for argument in "$@"; do
    case "$argument" in
        -o|ConnectTimeout=*|BatchMode=*) ;;
        192.0.2.*) remote_host="$argument" ;;
    esac
done
printf 'ssh %s\n' "$remote_host" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
remote_command=${*: -1}
if [ "${ODYSSEUS_TEST_BLOCK_WORKERS:-}" = ssh ]; then
    trap '' INT TERM HUP
    ODYSSEUS_TEST_WORKER_LEADER=$$ python3 -c '
import os, signal, time
os.setsid()
child = os.fork()
if child:
    os.waitpid(child, 0)
else:
    for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(value, signal.SIG_IGN)
    with open(os.environ["ODYSSEUS_TEST_WORKER_REGISTRY"], "a", encoding="ascii") as stream:
        stream.write("%s %s\n" % (os.environ["ODYSSEUS_TEST_WORKER_LEADER"], os.getpid()))
    while True:
        time.sleep(30)
' &
    descendant=$!
    wait "$descendant"
    exit 99
fi
if [ "${ODYSSEUS_TEST_SSH_FAIL_IP:-}" = "$remote_host" ]; then
    printf '%s\n' 'controlled ssh failure' >&2
    exit 55
fi
if [ "${ODYSSEUS_TEST_EXEC_REMOTE_SHELL:-0}" = 1 ]; then
    remote_script=$(cat)
    remote_home=${ODYSSEUS_TEST_REMOTE_HOME:?}
    counter_file=${ODYSSEUS_TEST_SSH_COUNTER:?}
    counter=0
    if [ -s "$counter_file" ]; then
        counter=$(<"$counter_file")
    fi
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$counter_file"
    run_dir=$(printf '%s\n' "$remote_command" | awk -F"'" '{print $2}')
    owner_token=${run_dir##*/}
    remote_run_path="$remote_home/$run_dir"
    race=${ODYSSEUS_TEST_REMOTE_RACE:-}
    race_victim_path=""
    if [ "$counter" -eq 2 ]; then
        case "$race" in
            run-dir-symlink)
                mkdir -p "$(dirname "$remote_run_path")" \
                    "${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}"
                ln -s "${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}" "$remote_run_path"
                race_victim_path="${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}/image.tar"
                ;;
            run-dir-existing)
                mkdir -p "$remote_run_path"
                cp "${ODYSSEUS_TEST_REMOTE_RACE_SEED:?}" \
                    "$remote_run_path/image.tar"
                race_victim_path="$remote_run_path/image.tar"
                ;;
        esac
    elif [ "$counter" -eq 3 ]; then
        launcher_root="$remote_home/alexnet-fleet-scripts"
        case "$race" in
            launcher-root-symlink)
                mkdir -p "${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}"
                ln -s "${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}" "$launcher_root"
                race_victim_path="${ODYSSEUS_TEST_REMOTE_VICTIM_DIR:?}/alexnet-train.sh"
                ;;
            launcher-root-file)
                cp "${ODYSSEUS_TEST_REMOTE_RACE_SEED:?}" "$launcher_root"
                race_victim_path="$launcher_root"
                ;;
            launcher-destination-existing)
                mkdir -p "$launcher_root"
                cp "${ODYSSEUS_TEST_REMOTE_RACE_SEED:?}" \
                    "$launcher_root/alexnet-train.sh"
                race_victim_path="$launcher_root/alexnet-train.sh"
                ;;
        esac
    elif [ "$counter" -eq 4 ]; then
        launcher_root="$remote_home/alexnet-fleet-scripts"
        launcher_stage="$launcher_root/.$owner_token/alexnet-train.sh"
        launcher_destination="$launcher_root/alexnet-train.sh"
        case "$race" in
            launcher-before-exec-symlink)
                rm -f -- "$launcher_destination"
                ln -s "${ODYSSEUS_TEST_REMOTE_VICTIM_FILE:?}" \
                    "$launcher_destination"
                race_victim_path=${ODYSSEUS_TEST_REMOTE_VICTIM_FILE:?}
                ;;
            helper-before-exec-inplace)
                helper_destination="$launcher_root/alexnet-collect-fs.py"
                "${ODYSSEUS_TEST_REAL_PYTHON:?}" - \
                    "$helper_destination" <<'PY'
import os
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    original = stream.read()
payload = (
    b"import os\n"
    b"open(os.environ['ODYSSEUS_TEST_REMOTE_EXEC_MARKER'], 'w').write('executed\\n')\n"
    b"raise SystemExit(91)\n"
)
if len(payload) > len(original):
    raise SystemExit("remote helper fixture is unexpectedly too small")
payload += b"#" * (len(original) - len(payload))
with open(path, "r+b", buffering=0) as stream:
    stream.write(payload)
    os.fsync(stream.fileno())
PY
                race_victim_path=$helper_destination
                ;;
            launcher-before-exec-inplace)
                "${ODYSSEUS_TEST_REAL_PYTHON:?}" - \
                    "$launcher_destination" <<'PY'
import os
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    original = stream.read()
payload = b"#!/usr/bin/env bash\nprintf '%s\\n' executed > \"${ODYSSEUS_TEST_REMOTE_EXEC_MARKER:?}\"\nexit 91\n"
if len(payload) > len(original):
    raise SystemExit("remote launcher fixture is unexpectedly too small")
payload += b"#" * (len(original) - len(payload))
with open(path, "r+b", buffering=0) as stream:
    stream.write(payload)
    os.fsync(stream.fileno())
PY
                race_victim_path=$launcher_destination
                ;;
            launcher-before-cleanup-replacement)
                rm -f -- "$launcher_destination"
                cp "$launcher_stage" "$launcher_destination"
                race_victim_path=$launcher_destination
                ;;
        esac
    fi
    if [ -n "$race_victim_path" ]; then
        printf '%s\n' "$race_victim_path" \
            > "${ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG:?}"
        /bin/ls -di "$race_victim_path" | awk '{print $1}' \
            > "${ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG:?}"
    fi
    ODYSSEUS_TEST_REMOTE_CONTEXT=1 HOME="$remote_home" \
        /bin/bash -c "$remote_command" <<< "$remote_script"
    exit
fi
if [ "${ODYSSEUS_TEST_SSH_OUTPUT+x}" = x ]; then
    printf '%s\n' "$ODYSSEUS_TEST_SSH_OUTPUT"
elif [[ "$remote_command" == "bash -s -- '.cache/odysseus-alexnet/"* ]]; then
    second_argument=$(printf '%s\n' "$remote_command" | awk -F"'" '{print $4}')
    if [ -z "$second_argument" ]; then
        printf '%s\n' '101:102'
    elif [[ ! "$second_argument" =~ ^[0-9]+:[0-9]+$ ]]; then
        printf '%s\n' '201:202:203:204:205:206:207:208:209:210'
    fi
else
    printf '%s\n' 'running 0'
fi
EOF

cat > "$fixture_bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
wait_container_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
train_image_id=${ODYSSEUS_TEST_IMAGE_ID:-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
if [ "${ODYSSEUS_TEST_REMOTE_CONTEXT:-0}" = 1 ]; then
    train_image_id=${ODYSSEUS_TEST_REMOTE_IMAGE_ID:-$train_image_id}
fi
chaos_container_id=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
chaos_binding_file=${ODYSSEUS_TEST_CHAOS_BINDING_FILE:-$HOME/.chaos-binding}
chaos_tracking=0
[ -n "${ODYSSEUS_TEST_CHAOS_LOG:-}" ] && chaos_tracking=1
chaos_seed_run=""
chaos_seed_image=$train_image_id
chaos_seed_id=""
if [ "$chaos_tracking" = 1 ] && [ -s "$chaos_binding_file" ]; then
    IFS='|' read -r chaos_seed_run chaos_seed_image chaos_seed_id \
        < "$chaos_binding_file"
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = "$wait_container_id" ] \
        && [ "${ODYSSEUS_TEST_CHAOS_REPLACE_C5:-0}" = 1 ]; then
    exit 125
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = "$wait_container_id" ] \
        && [ "${ODYSSEUS_TEST_TRAIN_EXACT_REPLACED:-0}" = 1 ]; then
    exit 125
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = "$chaos_container_id" ] \
        && [ "${ODYSSEUS_TEST_CHAOS_REPLACE_C5:-0}" = 1 ] \
        && [[ "$chaos_seed_run" == *-c5 ]]; then
    exit 125
fi
if [ "${1:-}" = inspect ] && [[ "$*" == *'.Image'* ]] \
        && [[ "$*" == *'.State.ExitCode'* ]]; then
    receipt_run=${ODYSSEUS_TEST_RECEIPT_RUN_ID:-${ALEXNET_RUN_ID:-test-run}}
    receipt_host=${ODYSSEUS_TEST_RECEIPT_HOST:-hub}
    receipt_results=${ODYSSEUS_TEST_RECEIPT_RESULTS_PATH:-$HOME/alexnet-results/runs/${ALEXNET_RUN_ID:-test-run}/$receipt_host}
    receipt_image=${ODYSSEUS_TEST_RECEIPT_IMAGE_ID:-$train_image_id}
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$wait_container_id" alexnet-training 'running 0' \
        "$receipt_run" "$receipt_results" "$receipt_image"
    exit 0
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = "$chaos_container_id" ]; then
    [ "$chaos_seed_id" = "$chaos_container_id" ] || exit 125
    if [ "${ODYSSEUS_TEST_CHAOS_REPLACE_C6:-0}" = 1 ] \
            && [ -z "${ODYSSEUS_TEST_CHAOS_VICTIM_MODE:-}" ]; then
        exit 125
    fi
    if [[ "$*" == *'.Mounts'* ]]; then
        chaos_seed_mount="$HOME/.cache/odysseus-alexnet-chaos/runs/$chaos_seed_run/hub"
        case "$chaos_seed_run" in
            *-c4) chaos_seed_mount="" ;;
        esac
        printf '%s|%s|%s|%s|%s\n' "$chaos_container_id" \
            alexnet-training "$chaos_seed_run" "$chaos_seed_image" \
            "$chaos_seed_mount"
    elif [[ "$*" == *'.Image'* ]]; then
        chaos_seed_state=running
        if [ "${ODYSSEUS_TEST_CHAOS_VICTIM_MODE:-}" = not-running ]; then
            chaos_seed_state=exited
        fi
        printf '%s|%s|%s|%s|%s\n' "$chaos_container_id" \
            alexnet-training "$chaos_seed_state" "$chaos_seed_run" "$chaos_seed_image"
    else
        printf '%s|%s|%s\n' "$chaos_container_id" \
            alexnet-training "$chaos_seed_run"
    fi
    exit 0
fi
case "${1:-} ${2:-}" in
    "info ")
        [ "${ODYSSEUS_TEST_PODMAN_INFO_FAIL:-0}" != 1 ]
        exit $?
        ;;
    "compose build"|"build -t") exit 0 ;;
    "image exists")
        if [ "${ODYSSEUS_TEST_IMAGE_EXISTS:-1}" = 1 ]; then
            exit 0
        fi
        exit 1
        ;;
    "image inspect")
        printf '%s\n' "$train_image_id"
        exit 0
        ;;
    "images "*)
        if [ "${ODYSSEUS_TEST_IMAGE_LIST+x}" = x ]; then
            printf '%s\n' "$ODYSSEUS_TEST_IMAGE_LIST"
        else
            printf '%s\n' "${2:-odyssey:dev}"
        fi
        exit 0
        ;;
    "container exists")
        container_target=${3:-}
        if [ -n "$chaos_seed_id" ] \
                && { [ "$container_target" = alexnet-training ] \
                    || [ "$container_target" = "$chaos_seed_id" ]; }; then
            exit 0
        fi
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" in
            absent) exit 1 ;;
            exists-fail) exit 125 ;;
            inspect-fail|running|paused|restarting|exited|created) exit 0 ;;
        esac
        ;;
    "rm -f")
        if [ -n "$chaos_seed_id" ] && [ "${3:-}" = "$chaos_seed_id" ]; then
            if [ "${ODYSSEUS_TEST_CHAOS_REPLACE_AFTER_RM:-0}" = 1 ]; then
                printf '%s|%s|%s\n' replacement-run "$chaos_seed_image" \
                    eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
                    > "$chaos_binding_file"
            else
                : > "$chaos_binding_file"
            fi
        fi
        exit 0
        ;;
    kill\ *)
        kill_rc=${ODYSSEUS_TEST_CHAOS_KILL_RC:-0}
        if [ "$kill_rc" != 0 ]; then
            exit "$kill_rc"
        fi
        if [ -n "${ODYSSEUS_TEST_CHAOS_STATE_FILE:-}" ]; then
            : > "$ODYSSEUS_TEST_CHAOS_STATE_FILE"
        fi
        exit 0
        ;;
    "save -o")
        output_path=${3:?}
        if [ "$output_path" != /tmp/odyssey-dev.tar ]; then
            : > "$output_path"
        fi
        exit 0
        ;;
    "create --cidfile")
        if [[ "$*" == *'sleep 600'* ]] \
            && [ "${ODYSSEUS_TEST_CHAOS_C4_SEED_RC:-0}" != 0 ]; then
            exit "$ODYSSEUS_TEST_CHAOS_C4_SEED_RC"
        fi
        if [[ "$*" == *'Training complete!'* ]] \
            && [ "${ODYSSEUS_TEST_CHAOS_C6_SEED_RC:-0}" != 0 ]; then
            exit "$ODYSSEUS_TEST_CHAOS_C6_SEED_RC"
        fi
        cidfile=${3:?}
        seed_run=""
        seed_image=$train_image_id
        for argument in "$@"; do
            case "$argument" in
                io.homeric.alexnet.run-id=*) seed_run=${argument#*=} ;;
            esac
        done
        printf '%s\n' "$chaos_container_id" > "$cidfile"
        if [ "${ODYSSEUS_TEST_CHAOS_RETARGET_CIDFILE:-0}" = 1 ]; then
            printf '%s\n' \
                eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
                > "$cidfile"
        fi
        printf '%s|%s|%s\n' "$seed_run" "$seed_image" \
            "$chaos_container_id" > "$chaos_binding_file"
        if [[ "$*" == *'Training complete!'* ]] \
                && [ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_SPAWN:-0}" = 1 ]; then
            kill -TERM "$PPID"
            /bin/sleep 30
            exit 143
        fi
        if [[ "$*" == *'Training complete!'* ]] \
                && [ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_BEFORE_PID:-0}" = 1 ]; then
            trap 'exit 143' INT TERM HUP
            /bin/sleep 3
            : > "${ODYSSEUS_TEST_CHAOS_NATURAL_FINISH:?}"
            exit 143
        fi
        printf '%s\n' "$chaos_container_id"
        exit 0
        ;;
    start\ *) exit 0 ;;
    "inspect alexnet-training")
        if [ -n "${ODYSSEUS_TEST_CHAOS_VICTIM_MODE:-}" ]; then
            chaos_run=$(awk '/^train run=.*-c5$/ { sub(/^train run=/, ""); value=$0 } END { print value }' \
                "${ODYSSEUS_TEST_CHAOS_LOG:?}")
            if [[ "$*" == *'.Mounts'* && "$*" == *'.Image'* ]]; then
                printf '%s|%s|%s|%s|%s\n' "$wait_container_id" \
                    alexnet-training "$chaos_run" "$train_image_id" \
                    "$HOME/alexnet-results/runs/$chaos_run/hub"
                exit 0
            elif [[ "$*" == *'Config.Labels'* ]]; then
                printf '%s|%s|%s\n' "$wait_container_id" \
                    alexnet-training "$chaos_run"
                exit 0
            fi
            victim_status=running
            victim_exit=0
            if [ "$ODYSSEUS_TEST_CHAOS_VICTIM_MODE" = not-running ]; then
                victim_status=exited
            elif [ -f "${ODYSSEUS_TEST_CHAOS_STATE_FILE:-/nonexistent}" ]; then
                victim_status=exited
                victim_exit=137
                if [ "$ODYSSEUS_TEST_CHAOS_VICTIM_MODE" = zero-exit ]; then
                    victim_exit=0
                fi
            fi
            if [[ "$*" == *'ExitCode'* ]]; then
                printf '%s exit=%s\n' "$victim_status" "$victim_exit"
            else
                printf '%s\n' "$victim_status"
            fi
            exit 0
        fi
        if [ -n "$chaos_seed_id" ] \
                && [[ "$*" == *'.Mounts'* && "$*" == *'.Image'* ]]; then
            chaos_seed_mount="$HOME/.cache/odysseus-alexnet-chaos/runs/$chaos_seed_run/hub"
            case "$chaos_seed_run" in
                *-c4) chaos_seed_mount="" ;;
            esac
            printf '%s|%s|%s|%s|%s\n' "$chaos_seed_id" \
                alexnet-training "$chaos_seed_run" "$chaos_seed_image" \
                "$chaos_seed_mount"
            exit 0
        fi
        if [[ "$*" == *'.Id'* ]]; then
            printf '%s|%s|%s|%s\n' \
                "$wait_container_id" \
                alexnet-training \
                "${ODYSSEUS_TEST_RUN_ID:-test-run}" \
                "${ODYSSEUS_TEST_RESULTS_PATH:-$HOME/alexnet-results/runs/test-run/hub}"
            exit 0
        fi
        if [[ "$*" == *'.Mounts'* ]]; then
            state_value=${ODYSSEUS_TEST_PODMAN_STATE:-exited 0}
            if [ "${ODYSSEUS_TEST_STATE_MODE:-}" = running-then-exited ]; then
                counter_file=${ODYSSEUS_TEST_STATE_COUNTER:?}
                counter=0
                if [ -f "$counter_file" ]; then
                    counter=$(<"$counter_file")
                fi
                counter=$((counter + 1))
                printf '%s\n' "$counter" > "$counter_file"
                if [ "$counter" -eq 1 ]; then
                    state_value='running 0'
                else
                    state_value='exited 0'
                fi
            fi
            printf '%s|%s|%s\n' \
                "$state_value" \
                "${ODYSSEUS_TEST_RUN_ID:-test-run}" \
                "${ODYSSEUS_TEST_RESULTS_PATH:-$HOME/alexnet-results/runs/test-run/hub}"
            exit 0
        fi
        if [ "${ODYSSEUS_TEST_CONTAINER_MODE:-}" = inspect-fail ]; then
            exit 125
        fi
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-}" in
            running|paused|restarting|exited|created)
                printf '%s\n' "$ODYSSEUS_TEST_CONTAINER_MODE"
                ;;
            *)
                if [ "${ODYSSEUS_TEST_STATE_MODE:-}" = running-then-exited ]; then
                    counter_file=${ODYSSEUS_TEST_STATE_COUNTER:?}
                    counter=0
                    if [ -f "$counter_file" ]; then
                        counter=$(<"$counter_file")
                    fi
                    counter=$((counter + 1))
                    printf '%s\n' "$counter" > "$counter_file"
                    if [ "$counter" -eq 1 ]; then
                        printf '%s\n' 'running 0'
                    else
                        printf '%s\n' 'exited 0'
                    fi
                else
                    printf '%s\n' "${ODYSSEUS_TEST_PODMAN_STATE:-exited 0}"
                fi
                ;;
        esac
        exit 0
        ;;
    "inspect $wait_container_id")
        if [ -n "${ODYSSEUS_TEST_CHAOS_VICTIM_MODE:-}" ]; then
            chaos_run=$(awk '/^train run=.*-c5$/ { sub(/^train run=/, ""); value=$0 } END { print value }' \
                "${ODYSSEUS_TEST_CHAOS_LOG:?}")
            victim_status=running
            victim_exit=0
            if [ "$ODYSSEUS_TEST_CHAOS_VICTIM_MODE" = not-running ]; then
                victim_status=exited
            elif [ -f "${ODYSSEUS_TEST_CHAOS_STATE_FILE:-/nonexistent}" ]; then
                victim_status=exited
                victim_exit=137
                if [ "$ODYSSEUS_TEST_CHAOS_VICTIM_MODE" = zero-exit ]; then
                    victim_exit=0
                fi
            fi
            if [[ "$*" == *'.Mounts'* && "$*" == *'.Image'* ]]; then
                printf '%s|%s|%s|%s|%s\n' "$wait_container_id" \
                    alexnet-training "$chaos_run" "$train_image_id" \
                    "$HOME/alexnet-results/runs/$chaos_run/hub"
            elif [[ "$*" == *'ExitCode'* ]]; then
                printf '%s|%s|%s exit=%s|%s\n' "$wait_container_id" \
                    alexnet-training "$victim_status" "$victim_exit" "$chaos_run"
            else
                printf '%s|%s|%s|%s\n' "$wait_container_id" \
                    alexnet-training "$victim_status" "$chaos_run"
            fi
            exit 0
        fi
        if [[ "$*" == *'.Image'* && "$*" == *'.Mounts'* \
                && "$*" != *'.State.Status'* ]]; then
            receipt_run=${ODYSSEUS_TEST_RECEIPT_RUN_ID:-${ALEXNET_RUN_ID:-test-run}}
            receipt_host=${ODYSSEUS_TEST_RECEIPT_HOST:-hub}
            receipt_results=${ODYSSEUS_TEST_RECEIPT_RESULTS_PATH:-$HOME/alexnet-results/runs/${ALEXNET_RUN_ID:-test-run}/$receipt_host}
            receipt_image=${ODYSSEUS_TEST_RECEIPT_IMAGE_ID:-$train_image_id}
            printf '%s|%s|%s|%s|%s\n' \
                "$wait_container_id" alexnet-training "$receipt_run" \
                "$receipt_image" "$receipt_results"
            exit 0
        fi
        if [ "${ODYSSEUS_TEST_WAIT_REPLACEMENT_RACE:-0}" = 1 ] \
                && [ -e "${ODYSSEUS_TEST_WAIT_RACE_MARKER:?}" ]; then
            exit 125
        fi
        state_value=${ODYSSEUS_TEST_PODMAN_STATE:-exited 0}
        if [ "${ODYSSEUS_TEST_STATE_MODE:-}" = running-then-exited ]; then
            counter_file=${ODYSSEUS_TEST_STATE_COUNTER:?}
            counter=0
            if [ -f "$counter_file" ]; then
                counter=$(<"$counter_file")
            fi
            counter=$((counter + 1))
            printf '%s\n' "$counter" > "$counter_file"
            if [ "$counter" -eq 1 ]; then
                state_value='running 0'
            else
                state_value='exited 0'
            fi
        fi
        printf '%s|%s|%s|%s|%s\n' \
            "$wait_container_id" \
            alexnet-training \
            "$state_value" \
            "${ODYSSEUS_TEST_RUN_ID:-test-run}" \
            "${ODYSSEUS_TEST_RESULTS_PATH:-$HOME/alexnet-results/runs/test-run/hub}"
        if [ "${ODYSSEUS_TEST_WAIT_REPLACEMENT_RACE:-0}" = 1 ]; then
            : > "${ODYSSEUS_TEST_WAIT_RACE_MARKER:?}"
        fi
        exit 0
        ;;
    "logs alexnet-training")
        [ "${ODYSSEUS_TEST_MARKER:-present}" = present ] || exit 0
        if [ "${ODYSSEUS_TEST_MARKER_FIRST:-0}" = 1 ]; then
            printf '%s\n' 'Training complete!'
        fi
        if [ "${ODYSSEUS_TEST_LARGE_LOG_MIB:-0}" -gt 0 ]; then
            /bin/dd if=/dev/zero bs=1048576 \
                count="$ODYSSEUS_TEST_LARGE_LOG_MIB" 2>/dev/null \
                | /usr/bin/tr '\0' x
            printf '\n'
        fi
        [ "${ODYSSEUS_TEST_MARKER_FIRST:-0}" = 1 ] \
            || printf '%s\n' 'Training complete!'
        exit 0
        ;;
    "logs $wait_container_id")
        [ "${ODYSSEUS_TEST_MARKER:-present}" = present ] || exit 0
        if [ "${ODYSSEUS_TEST_MARKER_FIRST:-0}" = 1 ]; then
            printf '%s\n' 'Training complete!'
        fi
        if [ "${ODYSSEUS_TEST_LARGE_LOG_MIB:-0}" -gt 0 ]; then
            /bin/dd if=/dev/zero bs=1048576 \
                count="$ODYSSEUS_TEST_LARGE_LOG_MIB" 2>/dev/null \
                | /usr/bin/tr '\0' x
            printf '\n'
        fi
        [ "${ODYSSEUS_TEST_MARKER_FIRST:-0}" = 1 ] \
            || printf '%s\n' 'Training complete!'
        exit 0
        ;;
    "run -d")
        if [[ "$*" == *'sleep 600'* ]] \
            && [ "${ODYSSEUS_TEST_CHAOS_C4_SEED_RC:-0}" != 0 ]; then
            exit "$ODYSSEUS_TEST_CHAOS_C4_SEED_RC"
        fi
        if [[ "$*" == *'Training complete!'* ]] \
            && [ "${ODYSSEUS_TEST_CHAOS_C6_SEED_RC:-0}" != 0 ]; then
            exit "$ODYSSEUS_TEST_CHAOS_C6_SEED_RC"
        fi
        if [ "${ODYSSEUS_TEST_TRAIN_MOUNT_RACE:-0}" = 1 ]; then
            runs_root="${ODYSSEUS_TEST_TRAIN_RESULTS_ROOT:?}/runs"
            /bin/mv -- "$runs_root" "${ODYSSEUS_TEST_TRAIN_HELD_ROOT:?}"
            /bin/ln -s -- "${ODYSSEUS_TEST_TRAIN_VICTIM_ROOT:?}" "$runs_root"
            for argument in "$@"; do
                case "$argument" in
                    *:/results:Z)
                        result_source=${argument%:/results:Z}
                        case "$result_source" in
                            /dev/fd/*|/proc/self/fd/*)
                                result_fd=${result_source##*/}
                                /usr/bin/python3 - "$result_fd" <<'PY'
import os
import sys

descriptor = os.open(
    "container-result.txt",
    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
    0o600,
    dir_fd=int(sys.argv[1]),
)
os.write(descriptor, b"container result\n")
os.close(descriptor)
PY
                                ;;
                            *)
                                printf '%s\n' 'container result' \
                                    > "$result_source/container-result.txt"
                                ;;
                        esac
                        ;;
                esac
            done
        fi
        if [ "$chaos_tracking" = 1 ] \
                && [[ "$*" == *'io.homeric.alexnet.run-id='* ]]; then
            seed_run=""
            seed_image=$train_image_id
            for argument in "$@"; do
                case "$argument" in
                    io.homeric.alexnet.run-id=*) seed_run=${argument#*=} ;;
                esac
            done
            if [ "${ODYSSEUS_TEST_CHAOS_RETARGET_C6:-0}" = 1 ] \
                    && [[ " $* " == *' localhost/odyssey:dev '* ]]; then
                seed_image=${ODYSSEUS_TEST_CHAOS_RETARGET_IMAGE_ID:-sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}
            fi
            printf '%s|%s|%s\n' "$seed_run" "$seed_image" \
                "$chaos_container_id" \
                > "$chaos_binding_file"
            if [[ "$*" == *'Training complete!'* ]] \
                    && [ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_SPAWN:-0}" = 1 ]; then
                kill -TERM "$PPID"
                /bin/sleep 30
                exit 143
            fi
            if [[ "$*" == *'Training complete!'* ]] \
                    && [ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_BEFORE_PID:-0}" = 1 ]; then
                trap 'exit 143' INT TERM HUP
                /bin/sleep 3
                : > "${ODYSSEUS_TEST_CHAOS_NATURAL_FINISH:?}"
                exit 143
            fi
        fi
        if [ "$chaos_tracking" = 1 ]; then
            printf '%s\n' "$chaos_container_id"
        else
            printf '%s\n' "$wait_container_id"
        fi
        exit 0
        ;;
esac
exit 0
EOF

cat > "$fixture_bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
if [ "${ODYSSEUS_TEST_BLOCK_WORKERS:-}" = rsync ]; then
    trap '' INT TERM HUP
    ODYSSEUS_TEST_WORKER_LEADER=$$ python3 -c '
import os, signal, time
os.setsid()
child = os.fork()
if child:
    os.waitpid(child, 0)
else:
    for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(value, signal.SIG_IGN)
    with open(os.environ["ODYSSEUS_TEST_WORKER_REGISTRY"], "a", encoding="ascii") as stream:
        stream.write("%s %s\n" % (os.environ["ODYSSEUS_TEST_WORKER_LEADER"], os.getpid()))
    while True:
        time.sleep(30)
' &
    descendant=$!
    wait "$descendant"
    exit 99
fi
source_path=${*: -2:1}
destination=${*: -1}
if [ "${ODYSSEUS_TEST_EXEC_REMOTE_SHELL:-0}" = 1 ]; then
    case "$destination" in
        192.0.2.*:~/*)
            image_source=${*: -4:1}
            launcher_source=${*: -3:1}
            helper_source=${*: -2:1}
            remote_relative=${destination#*:~/}
            remote_destination="${ODYSSEUS_TEST_REMOTE_HOME:?}/$remote_relative"
            cp "$image_source" "$launcher_source" "$helper_source" \
                "$remote_destination/"
            exit 0
            ;;
    esac
fi
case "$source_path" in
    192.0.2.*:*)
        source_ip=${source_path%%:*}
        if [ "${ODYSSEUS_TEST_RSYNC_FAIL_IP:-}" = "$source_ip" ]; then
            printf '%s\n' 'controlled rsync failure' >&2
            exit 23
        fi
        mkdir -p "$destination"
        if [ "${ODYSSEUS_TEST_RSYNC_STRIP_HEADER_IP:-}" = "$source_ip" ]; then
            printf '%s\n' "result replaced after preflight on $source_ip" \
                > "$destination/training.log"
        else
            {
                printf '%s\n' '=== AlexNet Training on remote ==='
                printf 'Run ID:   %s\n' "${ALEXNET_RUN_ID:-test-run}"
                printf '%s\n' "result from $source_ip"
            } > "$destination/training.log"
        fi
        if [ -n "${ODYSSEUS_TEST_COLLECT_HARDLINK_VICTIM:-}" ]; then
            /bin/ln -- "$ODYSSEUS_TEST_COLLECT_HARDLINK_VICTIM" \
                "$destination/injected-hardlink"
        fi
        if [ "${ODYSSEUS_TEST_COLLECT_PARENT_RACE:-0}" = 1 ]; then
            staging_name=""
            for candidate in \
                "${ODYSSEUS_TEST_COLLECT_PARENT:?}"/.alexnet-collect.*; do
                if [ -d "$candidate" ]; then
                    staging_name=${candidate##*/}
                    break
                fi
            done
            [ -n "$staging_name" ] || exit 91
            /bin/mv -- "$ODYSSEUS_TEST_COLLECT_PARENT" \
                "${ODYSSEUS_TEST_COLLECT_HELD_PARENT:?}"
            decoy="${ODYSSEUS_TEST_COLLECT_VICTIM_PARENT:?}/$staging_name"
            /bin/mkdir -p -- "$decoy"
            printf '%s\n' 'victim staging evidence' > "$decoy/victim.txt"
            printf '%s\n' "$decoy" \
                > "${ODYSSEUS_TEST_COLLECT_RACE_DECOY_LOG:?}"
            /bin/ln -s -- "$ODYSSEUS_TEST_COLLECT_VICTIM_PARENT" \
                "$ODYSSEUS_TEST_COLLECT_PARENT"
        fi
        ;;
    *)
        destination_ip=${destination%%:*}
        if [ "${ODYSSEUS_TEST_RSYNC_FAIL_IP:-}" = "$destination_ip" ]; then
            printf '%s\n' 'controlled rsync failure' >&2
            exit 23
        fi
        ;;
esac
EOF

cat > "$fixture_bin/rm" <<'EOF'
#!/usr/bin/env bash
target=${*: -1}
if [ -n "${ODYSSEUS_TEST_WORKER_REGISTRY:-}" ] \
        && [ -s "$ODYSSEUS_TEST_WORKER_REGISTRY" ] \
        && [[ "$target" == *odysseus-alexnet-deploy.* ]]; then
    while read -r leader descendant; do
        for worker_pid in "$leader" "$descendant"; do
            if /bin/kill -0 "$worker_pid" 2>/dev/null; then
                printf '%s\n' "$worker_pid" \
                    >> "${ODYSSEUS_TEST_CLEANUP_RACE_LOG:?}"
            fi
        done
    done < "$ODYSSEUS_TEST_WORKER_REGISTRY"
fi
if [ "${ODYSSEUS_TEST_REMOTE_CONTEXT:-0}" = 1 ] \
        && [ "${ODYSSEUS_TEST_REMOTE_RACE:-}" = launcher-after-cleanup-check ] \
        && [[ "$target" == */alexnet-fleet-scripts/alexnet-train.sh ]] \
        && [ ! -e "${ODYSSEUS_TEST_REMOTE_RACE_TRIGGERED:?}" ]; then
    /bin/mv -- "$target" "${ODYSSEUS_TEST_REMOTE_RACE_HELD:?}"
    /bin/cp -- "${ODYSSEUS_TEST_REMOTE_RACE_SEED:?}" "$target"
    printf '%s\n' "$target" > "${ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG:?}"
    /bin/ls -di "$target" | awk '{print $1}' \
        > "${ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG:?}"
    : > "$ODYSSEUS_TEST_REMOTE_RACE_TRIGGERED"
fi
exec /bin/rm "$@"
EOF

chmod +x "$fixture_bin"/*

run_operation() {
    local case_name=$1
    local script=$2
    shift 2
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$fixture_root/$case_name.ssh"
    local script_path="$script"
    if [[ "$script_path" != /* ]]; then
        script_path="$ROOT/$script_path"
    fi
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CLOCK_COUNTER="$fixture_root/$case_name.clock" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_REMOTE_HOME="$fixture_root/$case_name.remote-home" \
    ODYSSEUS_TEST_SSH_COUNTER="$fixture_root/$case_name.ssh" \
    ODYSSEUS_TEST_STATE_COUNTER="$fixture_root/$case_name.state" \
    TMPDIR="$fixture_root" \
    HOME="$fixture_root/home" \
    SETTLE_SECONDS=0 \
    MARKER_RETRY_DELAY=0 \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$@" bash "$script_path" > "$fixture_root/$case_name.out" 2>&1
}

run_operation_bounded() {
    local case_name=$1
    local script=$2
    shift 2
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$fixture_root/$case_name.ssh"
    local script_path="$script"
    if [[ "$script_path" != /* ]]; then
        script_path="$ROOT/$script_path"
    fi
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CLOCK_COUNTER="$fixture_root/$case_name.clock" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_REMOTE_HOME="$fixture_root/$case_name.remote-home" \
    ODYSSEUS_TEST_SSH_COUNTER="$fixture_root/$case_name.ssh" \
    ODYSSEUS_TEST_STATE_COUNTER="$fixture_root/$case_name.state" \
    TMPDIR="$fixture_root" HOME="$fixture_root/home" \
    SETTLE_SECONDS=0 MARKER_RETRY_DELAY=0 \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$real_python" -I -E - "$script_path" "$@" \
            > "$fixture_root/$case_name.out" 2>&1 <<'PY'
import os
import signal
import subprocess
import sys

script, *prefix = sys.argv[1:]
process = subprocess.Popen(
    [*prefix, "/bin/bash", script],
    env=os.environ.copy(),
    start_new_session=True,
)
try:
    raise SystemExit(process.wait(timeout=15))
except subprocess.TimeoutExpired:
    try:
        listing = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid="], text=True
        )
    except (OSError, subprocess.SubprocessError):
        listing = ""
    children = {}
    for line in listing.splitlines():
        try:
            child, parent = map(int, line.split())
        except ValueError:
            continue
        children.setdefault(parent, []).append(child)
    pending = list(children.get(process.pid, ()))
    descendants = []
    while pending:
        child = pending.pop()
        descendants.append(child)
        pending.extend(children.get(child, ()))
    for child in reversed(descendants):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait()
    print("operation exceeded its 15-second test bound", file=sys.stderr)
    raise SystemExit(124)
PY
}

assert_no_target_effects() {
    local case_name=$1
    if grep -Eq '^(podman|ssh|rsync) ' "$fixture_root/$case_name.effects"; then
        fail "$case_name reached a target operation"
        return 1
    fi
    return 0
}

run_train() {
    local case_name=$1
    shift
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CLOCK_COUNTER="$fixture_root/$case_name.clock" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_STATE_COUNTER="$fixture_root/$case_name.state" \
    TMPDIR="$fixture_root" \
    HOME="$fixture_root/home" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        env WORKSPACE_DIR="$fixture_root/workspace" MAX_BATCHES=3 "$@" \
        bash "$ROOT/e2e/alexnet-train.sh" \
        > "$fixture_root/$case_name.out" 2>&1
}

signal_fleet_operation() {
    local case_name=$1
    local script=$2
    local signal_name=$3
    local cleanup_pattern=$4
    local registry="$fixture_root/$case_name.workers"
    local cleanup_race="$fixture_root/$case_name.cleanup-race"
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$registry"
    : > "$cleanup_race"
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CLOCK_COUNTER="$fixture_root/$case_name.clock" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_REMOTE_HOME="$fixture_root/$case_name.remote-home" \
    ODYSSEUS_TEST_SSH_COUNTER="$fixture_root/$case_name.ssh" \
    ODYSSEUS_TEST_STATE_COUNTER="$fixture_root/$case_name.state" \
    ODYSSEUS_TEST_WORKER_REGISTRY="$registry" \
    ODYSSEUS_TEST_CLEANUP_RACE_LOG="$cleanup_race" \
    TMPDIR="$fixture_root" \
    HOME="$fixture_root/home" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$real_python" - "$ROOT/$script" "$signal_name" "$registry" \
            "$fixture_root/$case_name.out" "$fixture_root/$cleanup_pattern" <<'PY'
import glob
import os
import shutil
import signal
import subprocess
import sys
import time

script, signal_name, registry, output_path, cleanup_pattern = sys.argv[1:]
expect_retain = os.environ.get("ODYSSEUS_TEST_EXPECT_RETAIN") == "1"
expected_retained_paths = int(
    os.environ.get("ODYSSEUS_TEST_EXPECT_RETAINED_PATHS", "0")
)
existing_cleanup_paths = set(glob.glob(cleanup_pattern))
with open(output_path, "wb") as output:
    process = subprocess.Popen(
        ["/bin/bash", script],
        env=os.environ.copy(),
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    if os.path.exists(registry) and os.path.getsize(registry) > 0:
        break
    if process.poll() is not None:
        raise SystemExit(f"operation exited before a worker was registered: {process.returncode}")
    time.sleep(0.05)
else:
    process.kill()
    process.wait()
    raise SystemExit("operation did not register a worker")

os.kill(process.pid, getattr(signal, f"SIG{signal_name}"))
try:
    return_code = process.wait(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("operation did not stop after the signal")
if return_code == 0:
    raise SystemExit("signalled operation returned success")

worker_pids = []
leaders = []
with open(registry, encoding="utf-8") as workers:
    for line in workers:
        values = [int(value) for value in line.split()]
        if values:
            leaders.append(values[0])
            worker_pids.extend(values)
new_cleanup_paths = set(glob.glob(cleanup_pattern)) - existing_cleanup_paths
if expect_retain:
    if len(new_cleanup_paths) != expected_retained_paths:
        raise SystemExit(
            f"expected {expected_retained_paths} retained path(s), "
            f"got {sorted(new_cleanup_paths)}"
        )
    for leader in leaders:
        try:
            os.killpg(leader, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for worker_pid in worker_pids:
        try:
            os.kill(worker_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for cleanup_path in new_cleanup_paths:
        shutil.rmtree(cleanup_path)
    raise SystemExit(0)
for worker_pid in worker_pids:
    for _ in range(40):
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for cleanup_pid in worker_pids:
            try:
                os.kill(cleanup_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        raise SystemExit(f"worker {worker_pid} survived operation shutdown")
if new_cleanup_paths:
    raise SystemExit(f"operation left cleanup paths: {sorted(new_cleanup_paths)}")
PY
}

kill_failure_env="$fixture_root/kill-failure.bash"
cat > "$kill_failure_env" <<'EOF'
kill() {
    if [ "${ODYSSEUS_TEST_FAIL_GROUP_KILL:-0}" = 1 ] \
            && [ "${1:-}" = -KILL ]; then
        return 77
    fi
    builtin kill "$@"
}
EOF

signal_fleet_extinction_failure() {
    local case_name=$1
    local registry="$fixture_root/$case_name.workers"
    local cleanup_race="$fixture_root/$case_name.cleanup-race"
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$registry"
    : > "$cleanup_race"
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CLOCK_COUNTER="$fixture_root/$case_name.clock" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_REMOTE_HOME="$fixture_root/$case_name.remote-home" \
    ODYSSEUS_TEST_SSH_COUNTER="$fixture_root/$case_name.ssh" \
    ODYSSEUS_TEST_STATE_COUNTER="$fixture_root/$case_name.state" \
    ODYSSEUS_TEST_WORKER_REGISTRY="$registry" \
    ODYSSEUS_TEST_CLEANUP_RACE_LOG="$cleanup_race" \
    TMPDIR="$fixture_root" HOME="$fixture_root/home" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$real_python" - "$ROOT/e2e/alexnet-deploy-fleet.sh" \
            "$registry" "$fixture_root/$case_name.out" \
            "$fixture_root/odysseus-alexnet-deploy.*" \
            "$cleanup_race" <<'PY'
import glob
import os
import shutil
import signal
import subprocess
import sys
import time

script, registry, output_path, cleanup_pattern, cleanup_race = sys.argv[1:]
existing = set(glob.glob(cleanup_pattern))
with open(output_path, "wb") as output:
    process = subprocess.Popen(
        ["/bin/bash", script],
        env=os.environ.copy(),
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    if os.path.exists(registry) and os.path.getsize(registry) > 0:
        break
    if process.poll() is not None:
        raise SystemExit(f"operation exited before worker registration: {process.returncode}")
    time.sleep(0.05)
else:
    process.kill()
    process.wait()
    raise SystemExit("operation did not register a worker")
os.kill(process.pid, signal.SIGTERM)
try:
    return_code = process.wait(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("operation did not bound its failed worker shutdown")
if return_code == 0:
    raise SystemExit("failed worker extinction was reported as success")
retained = set(glob.glob(cleanup_pattern)) - existing
if len(retained) != 1:
    raise SystemExit(f"expected one retained diagnostic directory, got {sorted(retained)}")
if os.path.getsize(cleanup_race) != 0:
    raise SystemExit("cleanup ran while worker extinction remained unverified")
leaders = []
worker_pids = []
with open(registry, encoding="utf-8") as workers:
    for line in workers:
        values = [int(value) for value in line.split()]
        if values:
            leaders.append(values[0])
            worker_pids.extend(values)
for leader in leaders:
    try:
        os.killpg(leader, signal.SIGKILL)
    except ProcessLookupError:
        pass
for worker_pid in worker_pids:
    try:
        os.kill(worker_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
for retained_path in retained:
    shutil.rmtree(retained_path)
PY
}

mkdir -p "$fixture_root/workspace/research/Odyssey"
mkdir -p "$fixture_root/home/alexnet-results/runs/test-run/hub/alexnet_weights"
printf '%s\n' '=== AlexNet Training on hub ===' \
    > "$fixture_root/home/alexnet-results/runs/test-run/hub/training.log"
printf '%s\n' 'Run ID:   test-run' \
    >> "$fixture_root/home/alexnet-results/runs/test-run/hub/training.log"
printf '%s\n' stale \
    > "$fixture_root/home/alexnet-results/runs/test-run/hub/alexnet_weights/stale.bin"
touch -t 202001010000 \
    "$fixture_root/home/alexnet-results/runs/test-run/hub/alexnet_weights/stale.bin"
touch -t 202101010000 \
    "$fixture_root/home/alexnet-results/runs/test-run/hub/training.log"
mkdir -p "$fixture_root/home/alexnet-results/hub/alexnet_weights"
printf '%s\n' '=== AlexNet Training on hub ===' \
    > "$fixture_root/home/alexnet-results/hub/training.log"
printf '%s\n' stale \
    > "$fixture_root/home/alexnet-results/hub/alexnet_weights/stale.bin"
touch -t 202001010000 \
    "$fixture_root/home/alexnet-results/hub/alexnet_weights/stale.bin"
touch -t 202101010000 \
    "$fixture_root/home/alexnet-results/hub/training.log"

info "fleet input is exact, non-empty, valid, and deduplicated"
for script in \
    e2e/alexnet-deploy-fleet.sh \
    e2e/alexnet-fleet-wait.sh \
    e2e/alexnet-collect-results.sh; do
    case_name="empty-$(basename "$script" .sh)"
    if run_operation "$case_name" "$script" env FLEET= LOCAL_AS_BUILD=1; then
        fail "$script accepted an explicitly empty fleet"
    elif assert_no_target_effects "$case_name"; then
        if grep -Fq 'at least one host' "$fixture_root/$case_name.out"; then
            pass "$script rejects an explicitly empty fleet before target effects"
        else
            fail "$script did not identify the explicitly empty fleet"
        fi
    fi

    case_name="duplicate-$(basename "$script" .sh)"
    if run_operation "$case_name" "$script" env \
        FLEET='hub hub' ALEXNET_DEPLOY_APPROVED_FLEET='hub hub' \
        POLL_INTERVAL=1 CENTRAL_DIR="$fixture_root/$case_name-results"; then
        fail "$script accepted a duplicate fleet target"
    elif assert_no_target_effects "$case_name"; then
        if grep -Fq 'duplicate host' "$fixture_root/$case_name.out"; then
            pass "$script rejects duplicate targets before target effects"
        else
            fail "$script did not identify the duplicate fleet target"
        fi
    fi
done

info "fleet aliases cannot select the same resolved target twice"
for script in \
    e2e/alexnet-deploy-fleet.sh \
    e2e/alexnet-fleet-wait.sh \
    e2e/alexnet-collect-results.sh; do
    case_name="local-alias-$(basename "$script" .sh)"
    if run_operation "$case_name" "$script" env \
        FLEET='hub localhost' ALEXNET_RUN_ID=test-run \
        ALEXNET_DEPLOY_APPROVED_FLEET='hub localhost' \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
        POLL_INTERVAL=1 CENTRAL_DIR="$fixture_root/$case_name-results"; then
        fail "$script accepted two aliases for the local target"
    elif ! assert_no_target_effects "$case_name"; then
        :
    elif grep -Fq 'duplicate resolved target' "$fixture_root/$case_name.out"; then
        pass "$script rejects two local aliases before target effects"
    else
        fail "$script did not identify the duplicate local target"
    fi

    case_name="peer-alias-$(basename "$script" .sh)"
    if run_operation "$case_name" "$script" env \
        FLEET='remote-one remote-alias' LOCAL_AS_BUILD=1 ALEXNET_RUN_ID=test-run \
        ALEXNET_DEPLOY_APPROVED_FLEET='remote-one remote-alias' \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
        ODYSSEUS_TEST_SSH_OUTPUT='exited 0' POLL_INTERVAL=1 \
        CENTRAL_DIR="$fixture_root/$case_name-results"; then
        fail "$script accepted two names for one peer address"
    elif ! assert_no_target_effects "$case_name"; then
        :
    elif grep -Fq 'duplicate resolved target' "$fixture_root/$case_name.out"; then
        pass "$script rejects duplicate peer addresses before target effects"
    else
        fail "$script did not identify the duplicate peer address"
    fi
done

unapproved_state_dir="$fixture_root/unapproved-deploy-state"
unapproved_state_file="$unapproved_state_dir/current-run.tsv"
unapproved_state_copy="$fixture_root/unapproved-deploy-state.expected"
mkdir -p "$unapproved_state_dir"
printf '%s\n' $'1\tactive-run\tlaunched\thub' > "$unapproved_state_file"
cp "$unapproved_state_file" "$unapproved_state_copy"
unapproved_state_inode=$(/bin/ls -di "$unapproved_state_file" | awk '{print $1}')
if run_operation unapproved-deploy-state e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub ALEXNET_RUN_STATE_DIR="$unapproved_state_dir"; then
    fail "unapproved deploy reported success"
elif ! assert_no_target_effects unapproved-deploy-state; then
    :
elif cmp -s "$unapproved_state_copy" "$unapproved_state_file" \
     && [ "$(/bin/ls -di "$unapproved_state_file" | awk '{print $1}')" \
          = "$unapproved_state_inode" ] \
     && grep -Fq 'ALEXNET_DEPLOY_APPROVED_FLEET' \
         "$fixture_root/unapproved-deploy-state.out"; then
    pass "unapproved deploy preserves the active run-state bytes and inode"
else
    fail "unapproved deploy changed the active run-state file"
fi

invalid_state_dir="$fixture_root/invalid-deploy-state"
invalid_state_file="$invalid_state_dir/current-run.tsv"
invalid_state_copy="$fixture_root/invalid-deploy-state.expected"
mkdir -p "$invalid_state_dir"
printf '%s\n' $'1\told-run\tlaunched\thub remote-one' > "$invalid_state_file"
cp "$invalid_state_file" "$invalid_state_copy"
invalid_state_inode=$(/bin/ls -di "$invalid_state_file" | awk '{print $1}')
if run_operation invalid-deploy-argument e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one' EPOCHS='1; touch /tmp/untrusted' LOCAL_AS_BUILD=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET='hub remote-one' \
    ALEXNET_RUN_STATE_DIR="$invalid_state_dir"; then
    fail "deploy accepted a shell-bearing numeric argument"
elif assert_no_target_effects invalid-deploy-argument; then
    if grep -Fq 'EPOCHS' "$fixture_root/invalid-deploy-argument.out" \
       && cmp -s "$invalid_state_copy" "$invalid_state_file" \
       && [ "$(/bin/ls -di "$invalid_state_file" | awk '{print $1}')" \
            = "$invalid_state_inode" ]; then
        pass "malformed deploy preserves the active run-state bytes and inode"
    else
        fail "malformed deploy changed the active run-state file"
    fi
fi

dry_state_dir="$fixture_root/dry-run-state"
mkdir -p "$dry_state_dir"
printf '%s\n' $'1\tactive-run\tlaunched\thub' \
    > "$dry_state_dir/current-run.tsv"
if run_operation deploy-dry-state e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub DRY_RUN=1 SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
    ALEXNET_RUN_STATE_DIR="$dry_state_dir"; then
    if grep -Fxq $'1\tactive-run\tlaunched\thub' \
       "$dry_state_dir/current-run.tsv"; then
        pass "deploy dry-run preserves the active current-run pointer"
    else
        fail "deploy dry-run replaced the active current-run pointer"
    fi
else
    fail "deploy dry-run could not complete its read-only preflight"
fi

if run_operation invalid-results-path e2e/alexnet-collect-results.sh env \
    FLEET=hub REMOTE_RESULTS_DIR='../../escape' \
    CENTRAL_DIR="$fixture_root/invalid-results"; then
    fail "collect accepted a parent-traversing remote results path"
elif assert_no_target_effects invalid-results-path; then
    if [ ! -e "$fixture_root/invalid-results" ]; then
        pass "collect rejects unsafe remote paths before creating output"
    else
        fail "collect created output for an unsafe remote path"
    fi
fi

info "deployment resolves and preflights the complete target set before mutation"
if run_operation deploy-unresolved e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub unresolved' LOCAL_AS_BUILD=1 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET='hub unresolved'; then
    fail "deploy skipped an unresolved requested target"
elif grep -Eq '^podman (compose|build|save)|^rsync ' \
     "$fixture_root/deploy-unresolved.effects"; then
    fail "deploy mutated state before complete fleet resolution"
elif grep -Fq 'fleet resolution is incomplete' \
     "$fixture_root/deploy-unresolved.out" \
     && [ "$(cut -f3 "$fixture_root/home/.cache/odysseus-alexnet/current-run.tsv")" = resolving ]; then
    pass "deploy invalidates prior current-run state while resolving the complete fleet"
else
    fail "deploy did not leave fail-closed state after incomplete fleet resolution"
fi

if run_operation deploy-preflight-failure e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one remote-two' LOCAL_AS_BUILD=1 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET='hub remote-one remote-two' \
    ODYSSEUS_TEST_SSH_FAIL_IP=192.0.2.12; then
    fail "deploy ignored a failed target preflight"
elif [ "$(grep -c '^ssh ' "$fixture_root/deploy-preflight-failure.effects")" -ne 2 ]; then
    fail "deploy did not inspect every target preflight result"
elif grep -Eq '^podman (compose|build|save)|^rsync ' \
     "$fixture_root/deploy-preflight-failure.effects"; then
    fail "deploy mutated state after an incomplete target preflight"
elif grep -Fq 'remote-one: preflight verified' \
     "$fixture_root/deploy-preflight-failure.out" \
     && grep -Fq 'remote-two: preflight failed' \
         "$fixture_root/deploy-preflight-failure.out"; then
    pass "deploy collects every preflight receipt before withholding mutation"
else
    fail "deploy omitted an exact target preflight receipt"
fi

for local_preflight_failure in engine image workspace; do
    case "$local_preflight_failure" in
        engine) local_preflight_input=ODYSSEUS_TEST_PODMAN_INFO_FAIL=1 ;;
        image) local_preflight_input=ODYSSEUS_TEST_IMAGE_EXISTS=0 ;;
        workspace) local_preflight_input=WORKSPACE_DIR="$fixture_root/missing-workspace" ;;
    esac
    local_preflight_case="deploy-local-preflight-$local_preflight_failure"
    if run_operation "$local_preflight_case" e2e/alexnet-deploy-fleet.sh env \
        FLEET=hub SKIP_BUILD=1 ALEXNET_DEPLOY_APPROVED_FLEET=hub \
        "$local_preflight_input"; then
        fail "deploy ignored local $local_preflight_failure preflight failure"
    elif grep -Eq '^podman (compose|build|save|run|create|start)|^rsync ' \
        "$fixture_root/$local_preflight_case.effects"; then
        fail "deploy mutated state after local $local_preflight_failure preflight failure"
    elif grep -Fq 'preflight failed' "$fixture_root/$local_preflight_case.out"; then
        pass "local $local_preflight_failure failure stops deployment before mutation"
    else
        fail "local $local_preflight_failure case did not reach the preflight boundary"
    fi
done

info "fleet signals stop and reap every owned background worker before cleanup"

worker_sentinel_swap_env="$fixture_root/worker-sentinel-swap.bash"
cat > "$worker_sentinel_swap_env" <<'EOF'
set -T
replace_worker_sentinel_before_child_bind() {
    if [[ ( "${BASH_COMMAND:-}" == 'exec 19< '* \
            || "${BASH_COMMAND:-}" == prepare_worker_sentinel* ) \
            && -n "${sentinel:-}" \
            && ! -e "${ODYSSEUS_TEST_WORKER_SWAP_DONE:?}" ]]; then
        trap - DEBUG
        /bin/mv -- "$sentinel" "${ODYSSEUS_TEST_WORKER_SWAP_HELD:?}"
        case "${ODYSSEUS_TEST_WORKER_SWAP_TYPE:?}" in
            fifo)
                /usr/bin/mkfifo "$sentinel"
                ;;
            socket)
                "${ODYSSEUS_TEST_REAL_PYTHON:?}" -I -E -c '
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
' "$sentinel"
                ;;
            *)
                exit 97
                ;;
        esac
        : > "$ODYSSEUS_TEST_WORKER_SWAP_DONE"
    fi
}
trap replace_worker_sentinel_before_child_bind DEBUG
EOF
worker_swap_tmp=$(mktemp -d /tmp/odax.XXXXXX)
for worker_swap_type in fifo socket; do
    worker_swap_case="deploy-worker-sentinel-$worker_swap_type"
    worker_swap_done="$fixture_root/$worker_swap_case.done"
    worker_swap_held="$fixture_root/$worker_swap_case.held"
    if run_operation_bounded "$worker_swap_case" \
        e2e/alexnet-deploy-fleet.sh env \
        FLEET=remote-one LOCAL_AS_BUILD=1 DRY_RUN=1 \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
        TMPDIR="$worker_swap_tmp" \
        BASH_ENV="$worker_sentinel_swap_env" \
        ODYSSEUS_TEST_WORKER_SWAP_TYPE="$worker_swap_type" \
        ODYSSEUS_TEST_WORKER_SWAP_DONE="$worker_swap_done" \
        ODYSSEUS_TEST_WORKER_SWAP_HELD="$worker_swap_held"; then
        if [ -e "$worker_swap_done" ] \
                && [ "$(wc -c < "$worker_swap_held" | tr -d ' ')" -eq 1 ] \
                && grep -Fxq R "$worker_swap_held" \
                && ! grep -Fq 'exceeded its 15-second test bound' \
                    "$fixture_root/$worker_swap_case.out"; then
            pass "deploy inherits the exact worker sentinel across a $worker_swap_type pathname replacement"
        else
            fail "deploy did not retain its exact worker sentinel across a $worker_swap_type replacement"
        fi
    else
        fail "deploy blocked on or reopened a $worker_swap_type worker sentinel replacement"
    fi
done
rm -r -- "$worker_swap_tmp"
worker_swap_tmp=""

for worker_signal in INT TERM HUP; do
    signal_case="deploy-signal-$(printf '%s' "$worker_signal" | tr '[:upper:]' '[:lower:]')"
    if FLEET=remote-one LOCAL_AS_BUILD=1 DRY_RUN=1 \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
        ALEXNET_RUN_ID="$signal_case" \
        ODYSSEUS_TEST_BLOCK_WORKERS=ssh \
        ODYSSEUS_TEST_EXPECT_RETAIN="$darwin_worker_fail_closed" \
        ODYSSEUS_TEST_EXPECT_RETAINED_PATHS="$darwin_worker_fail_closed" \
        signal_fleet_operation "$signal_case" \
            e2e/alexnet-deploy-fleet.sh "$worker_signal" \
            'odysseus-alexnet-deploy.*'; then
        if [ -s "$fixture_root/$signal_case.cleanup-race" ]; then
            fail "deploy $worker_signal cleanup ran before workers were reaped"
        else
            if [ "$darwin_worker_fail_closed" = 1 ]; then
                pass "deploy $worker_signal retains diagnostics when stable process handles are unavailable"
            else
                pass "deploy $worker_signal stops and reaps workers before scratch cleanup"
            fi
        fi
    else
        fail "deploy $worker_signal left an owned worker or scratch directory"
    fi
done

collect_signal_case=collect-signal-term
if FLEET=remote-one ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$fixture_root/$collect_signal_case-results" \
    ODYSSEUS_TEST_BLOCK_WORKERS=rsync \
    ODYSSEUS_TEST_EXPECT_RETAIN="$darwin_worker_fail_closed" \
    ODYSSEUS_TEST_EXPECT_RETAINED_PATHS=0 \
    signal_fleet_operation "$collect_signal_case" \
        e2e/alexnet-collect-results.sh TERM 'no-collect-cleanup.*'; then
    if [ "$darwin_worker_fail_closed" = 1 ]; then
        pass "collect TERM retains staging when stable process handles are unavailable"
    else
        pass "collect TERM stops and reaps every in-flight transfer worker"
    fi
else
    fail "collect TERM orphaned an in-flight transfer worker"
fi

if FLEET=remote-one LOCAL_AS_BUILD=1 DRY_RUN=1 \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
    ALEXNET_RUN_ID=deploy-extinction-failure \
    ODYSSEUS_TEST_BLOCK_WORKERS=ssh \
    ODYSSEUS_TEST_FAIL_GROUP_KILL=1 \
    ODYSSEUS_TEST_FAIL_HOLDER_SIGNAL=1 BASH_ENV="$kill_failure_env" \
    signal_fleet_extinction_failure deploy-extinction-failure; then
    if grep -Fq 'retained invocation directory' \
            "$fixture_root/deploy-extinction-failure.out"; then
        pass "deploy retains diagnostics when worker extinction cannot be verified"
    else
        fail "deploy omitted the retained-diagnostics receipt after failed extinction"
    fi
else
    fail "deploy deleted diagnostics after failed worker extinction"
fi

post_reap_hook="$fixture_root/post-reap-signal.bash"
cat > "$post_reap_hook" <<'EOF'
set -T
kill() {
    if [[ " $* " == *' -- -'* ]]; then
        printf 'group-kill %s\n' "$*" \
            >> "${ODYSSEUS_TEST_POST_REAP_KILL_LOG:?}"
    fi
    builtin kill "$@"
}
post_reap_signal() {
    if [[ "${BASH_COMMAND:-}" == forget_worker_pid* \
            && ! -e "${ODYSSEUS_TEST_POST_REAP_SEEN:?}" ]]; then
        : > "$ODYSSEUS_TEST_POST_REAP_SEEN"
        trap - DEBUG
        handle_worker_signal TERM 143
    fi
}
trap post_reap_signal DEBUG
EOF
post_reap_seen="$fixture_root/deploy-post-reap-signal.seen"
post_reap_kills="$fixture_root/deploy-post-reap-signal.kills"
: > "$post_reap_kills"
if run_operation deploy-post-reap-signal e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 DRY_RUN=1 \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
    BASH_ENV="$post_reap_hook" \
    ODYSSEUS_TEST_POST_REAP_SEEN="$post_reap_seen" \
    ODYSSEUS_TEST_POST_REAP_KILL_LOG="$post_reap_kills"; then
    fail "post-reap signal fixture unexpectedly completed"
elif [ ! -e "$post_reap_seen" ]; then
    fail "post-reap signal fixture did not reach the wait/forget window"
elif [ -s "$post_reap_kills" ]; then
    fail "post-reap signal targeted a stale or reused worker process group"
elif grep -Fq 'received SIGTERM' \
       "$fixture_root/deploy-post-reap-signal.out"; then
    pass "post-reap signal cannot target a stale worker PID or PGID"
else
    fail "post-reap signal was not handled deterministically"
fi

if run_operation wait-offline e2e/alexnet-fleet-wait.sh env \
    FLEET=offline ALEXNET_RUN_ID=test-run POLL_INTERVAL=1; then
    fail "wait accepted an offline peer address as current"
elif grep -q '^ssh ' "$fixture_root/wait-offline.effects"; then
    fail "wait probed a stale offline peer address"
elif grep -Fq 'fleet resolution is incomplete' "$fixture_root/wait-offline.out"; then
    pass "fleet resolution excludes stale offline peer addresses"
else
    fail "wait did not report the stale peer resolution failure"
fi

info "deployment uses invocation-unique artifacts and truthful fleet receipts"
if run_operation deploy-unapproved e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one' SKIP_LAUNCH=1; then
    fail "unapproved remote deployment reported success"
elif assert_no_target_effects deploy-unapproved \
     && grep -Fq 'ALEXNET_DEPLOY_APPROVED_FLEET' \
         "$fixture_root/deploy-unapproved.out"; then
    pass "remote deployment stops at the exact-fleet authority boundary"
else
    fail "remote deployment did not expose its exact approval route"
fi

if run_operation deploy-unapproved-local-build e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1; then
    fail "unapproved local image build reported success"
elif grep -Eq '^podman (compose build|build -t)' \
     "$fixture_root/deploy-unapproved-local-build.effects"; then
    fail "unapproved deployment reached the local image build"
elif grep -Fq 'ALEXNET_DEPLOY_APPROVED_FLEET' \
     "$fixture_root/deploy-unapproved-local-build.out"; then
    pass "non-interactive deployment approves the exact fleet before a local build"
else
    fail "local image build did not expose its exact approval route"
fi

if run_operation deploy-archive e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one' SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET='hub remote-one'; then
    if grep -Fq '/tmp/odyssey-dev.tar' "$fixture_root/deploy-archive.effects"; then
        fail "deploy used the shared fixed image archive"
    elif grep -Fq "$fixture_root/odysseus-alexnet-deploy." \
         "$fixture_root/deploy-archive.effects"; then
        pass "deploy image artifacts are unique to the invocation"
    else
        fail "deploy did not use its bounded invocation directory"
    fi
else
    fail "deployment with an invocation-only archive failed"
fi

if run_operation deploy-custom-image e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub IMAGE_NAME='odyssey.custom:review' SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET=hub; then
    if grep -Fq 'podman build -t odyssey.custom:review' \
        "$fixture_root/deploy-custom-image.effects"; then
        pass "deploy builds the exact requested nondefault image"
    else
        fail "deploy accepted a stale nondefault image without building that exact tag"
    fi
else
    fail "deploy could not produce the requested nondefault image"
fi

remote_image_mismatch_home="$fixture_root/deploy-remote-image-mismatch.remote-home"
mkdir -p "$remote_image_mismatch_home"
if run_operation deploy-remote-image-mismatch e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 \
    ALEXNET_RUN_ID=deploy-remote-image-mismatch \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    ODYSSEUS_TEST_REMOTE_IMAGE_ID=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; then
    fail "deploy accepted a remote image that differs from the bound local image"
elif grep -Fq 'remote image identity does not match the bound local image' \
       "$fixture_root/deploy-remote-image-mismatch.out" \
     && ! grep -Fq 'Fleet deployment verified' \
       "$fixture_root/deploy-remote-image-mismatch.out"; then
    pass "deploy requires the loaded remote image to equal the bound local image"
else
    fail "deploy did not expose the remote image identity mismatch"
fi

if run_operation deploy-launch-receipt-mismatch e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub ALEXNET_RUN_ID=deploy-launch-receipt-mismatch \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=0 \
    ALEXNET_DEPLOY_APPROVED_FLEET=hub \
    ODYSSEUS_TEST_PODMAN_STATE='running 0' \
    ODYSSEUS_TEST_RECEIPT_RUN_ID=wrong-run; then
    fail "deploy published launched state without an exact container receipt"
elif grep -Eq 'launch receipt|identity postcondition|did not publish an exact container ID' \
       "$fixture_root/deploy-launch-receipt-mismatch.out" \
     && [ "$(cut -f3 "$fixture_root/home/.cache/odysseus-alexnet/current-run.tsv")" \
        = launching ]; then
    pass "deploy withholds launched state until exact container receipts verify"
else
    fail "deploy did not retain launching state after the receipt mismatch"
fi

if run_operation deploy-spoofed-workflow e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one' SKIP_LAUNCH=1 GITHUB_ACTIONS=true \
    GITHUB_EVENT_NAME=workflow_dispatch; then
    fail "caller-controlled GitHub variables authorized deployment"
elif assert_no_target_effects deploy-spoofed-workflow \
     && grep -Fq 'ALEXNET_DEPLOY_APPROVED_FLEET' \
         "$fixture_root/deploy-spoofed-workflow.out"; then
    pass "non-interactive deployment requires an exact-fleet approval value"
else
    fail "spoofed workflow context did not stop at the approval boundary"
fi

if run_operation deploy-partial e2e/alexnet-deploy-fleet.sh env \
    FLEET='hub remote-one remote-two' LOCAL_AS_BUILD=1 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET='hub remote-one remote-two' \
    ODYSSEUS_TEST_RSYNC_FAIL_IP=192.0.2.12; then
    fail "partial fleet distribution reported success"
elif [ "$(grep -c '^rsync ' "$fixture_root/deploy-partial.effects")" -ne 2 ]; then
    fail "deploy did not collect every parallel distribution result"
elif ! grep -Fxq 'remote-one: transfer verified' "$fixture_root/deploy-partial.out" \
     || ! grep -Fq 'remote-two: transfer failed' "$fixture_root/deploy-partial.out"; then
    fail "deploy omitted an exact per-target transfer receipt"
elif grep -Fq 'Fleet deployment complete' "$fixture_root/deploy-partial.out"; then
    fail "partial fleet distribution emitted terminal completion"
else
    pass "deploy reports every parallel result and fails partial distribution"
fi

info "remote distribution refuses non-owned staging and launcher paths"
remote_race_seed="$fixture_root/remote-race.seed"
printf '%s\n' 'preserve these victim bytes' > "$remote_race_seed"
while IFS='|' read -r race_name expected_rsync_count; do
    case_name="deploy-$race_name"
    remote_home="$fixture_root/$case_name.remote-home"
    victim_dir="$remote_home/victim"
    race_path_log="$fixture_root/$case_name.race-path"
    race_inode_log="$fixture_root/$case_name.race-inode"
    mkdir -p "$remote_home"
    case "$race_name" in
        run-dir-symlink)
            mkdir -p "$victim_dir"
            cp "$remote_race_seed" "$victim_dir/image.tar"
            ;;
        launcher-root-symlink)
            mkdir -p "$victim_dir"
            cp "$remote_race_seed" "$victim_dir/alexnet-train.sh"
            ;;
    esac
    if run_operation "$case_name" e2e/alexnet-deploy-fleet.sh env \
        FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$case_name" \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=1 \
        ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
        ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
        ODYSSEUS_TEST_REMOTE_RACE="$race_name" \
        ODYSSEUS_TEST_REMOTE_RACE_SEED="$remote_race_seed" \
        ODYSSEUS_TEST_REMOTE_VICTIM_DIR="$victim_dir" \
        ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$race_path_log" \
        ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$race_inode_log"; then
        fail "deploy accepted remote race '$race_name'"
    elif [ ! -s "$race_path_log" ] || [ ! -s "$race_inode_log" ]; then
        fail "remote race fixture '$race_name' did not identify its victim"
    else
        victim_path=$(<"$race_path_log")
        victim_inode=$(<"$race_inode_log")
        rsync_count=$(grep -c '^rsync ' "$fixture_root/$case_name.effects")
        if [ -f "$victim_path" ] \
           && cmp -s "$remote_race_seed" "$victim_path" \
           && [ "$(/bin/ls -di "$victim_path" | awk '{print $1}')" \
                = "$victim_inode" ] \
           && [ "$rsync_count" -eq "$expected_rsync_count" ] \
           && ! grep -Fq 'Fleet deployment verified' \
               "$fixture_root/$case_name.out"; then
            pass "deploy rejects '$race_name' and preserves victim bytes and inode"
        else
            fail "deploy changed the victim or transfer boundary for '$race_name'"
        fi
    fi
done <<'EOF'
run-dir-symlink|0
run-dir-existing|0
launcher-root-symlink|1
launcher-root-file|1
launcher-destination-existing|1
EOF

remote_success_home="$fixture_root/deploy-remote-shell-success.remote-home"
mkdir -p "$remote_success_home/Projects/Odysseus/research/Odyssey"
if run_operation deploy-remote-shell-success e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 \
    ALEXNET_RUN_ID=deploy-remote-shell-success \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1; then
    if grep -Fq 'Fleet deployment verified for 1 requested host(s).' \
         "$fixture_root/deploy-remote-shell-success.out" \
       && [ -x "$remote_success_home/alexnet-fleet-scripts/alexnet-train.sh" ] \
       && [ -f "$remote_success_home/alexnet-fleet-scripts/alexnet-collect-fs.py" ]; then
        if run_operation deploy-remote-shell-reuse e2e/alexnet-deploy-fleet.sh env \
            FLEET=remote-one LOCAL_AS_BUILD=1 \
            ALEXNET_RUN_ID=deploy-remote-shell-reuse \
            SKIP_BUILD=1 SKIP_LAUNCH=0 \
            ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
            ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
            ODYSSEUS_TEST_REMOTE_HOME="$remote_success_home" \
            ODYSSEUS_TEST_RECEIPT_HOST=remote-one; then
            pass "distribution preserves the launcher contract for default image reuse"
        else
            fail "default reuse could not launch from the preserved remote tools"
        fi
    else
        fail "successful remote deployment removed its reusable remote tools"
    fi
else
    fail "safe remote shell deployment did not complete"
fi

stale_reuse_home="$fixture_root/deploy-stale-launcher-reuse.remote-home"
cp -R "$remote_success_home" "$stale_reuse_home"
printf '%s\n' '# stale launcher bytes' \
    >> "$stale_reuse_home/alexnet-fleet-scripts/alexnet-train.sh"
if run_operation deploy-stale-launcher-reuse e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 \
    ALEXNET_RUN_ID=deploy-stale-launcher-reuse \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=0 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_HOME="$stale_reuse_home" \
    ODYSSEUS_TEST_RECEIPT_HOST=remote-one; then
    fail "deploy reused stale remote launcher bytes"
elif grep -q '^podman run -d' \
       "$fixture_root/deploy-stale-launcher-reuse.effects"; then
    fail "stale launcher reuse reached container creation"
else
    pass "SKIP_DISTRIBUTE rejects stale remote launcher bytes"
fi

cleanup_race_name=deploy-launcher-before-cleanup-replacement
cleanup_race_home="$fixture_root/$cleanup_race_name.remote-home"
cleanup_race_path_log="$fixture_root/$cleanup_race_name.race-path"
cleanup_race_inode_log="$fixture_root/$cleanup_race_name.race-inode"
mkdir -p "$cleanup_race_home"
if run_operation "$cleanup_race_name" e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$cleanup_race_name" \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_RACE=launcher-before-cleanup-replacement \
    ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$cleanup_race_path_log" \
    ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$cleanup_race_inode_log"; then
    fail "deploy removed a same-content launcher replacement during cleanup"
elif [ ! -s "$cleanup_race_path_log" ] || [ ! -s "$cleanup_race_inode_log" ]; then
    fail "cleanup replacement fixture did not identify its victim"
else
    cleanup_victim_path=$(<"$cleanup_race_path_log")
    cleanup_victim_inode=$(<"$cleanup_race_inode_log")
    if [ -f "$cleanup_victim_path" ] \
       && cmp -s "$ROOT/e2e/alexnet-train.sh" "$cleanup_victim_path" \
       && [ "$(/bin/ls -di "$cleanup_victim_path" | awk '{print $1}')" \
            = "$cleanup_victim_inode" ] \
       && ! grep -Fq 'Fleet deployment verified' \
           "$fixture_root/$cleanup_race_name.out"; then
        pass "cleanup refuses a same-content launcher with a replacement inode"
    else
        fail "cleanup changed the same-content replacement launcher"
    fi
fi

after_check_name=deploy-launcher-after-cleanup-check
after_check_home="$fixture_root/$after_check_name.remote-home"
after_check_trigger="$fixture_root/$after_check_name.triggered"
after_check_held="$fixture_root/$after_check_name.held"
after_check_path_log="$fixture_root/$after_check_name.race-path"
after_check_inode_log="$fixture_root/$after_check_name.race-inode"
mkdir -p "$after_check_home"
after_check_rc=0
run_operation "$after_check_name" e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$after_check_name" \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=1 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_RACE=launcher-after-cleanup-check \
    ODYSSEUS_TEST_REMOTE_RACE_SEED="$remote_race_seed" \
    ODYSSEUS_TEST_REMOTE_RACE_TRIGGERED="$after_check_trigger" \
    ODYSSEUS_TEST_REMOTE_RACE_HELD="$after_check_held" \
    ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$after_check_path_log" \
    ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$after_check_inode_log" \
    || after_check_rc=$?
if [ "$after_check_rc" -eq 0 ] && [ ! -e "$after_check_trigger" ] \
        && cmp -s "$ROOT/e2e/alexnet-train.sh" \
            "$after_check_home/alexnet-fleet-scripts/alexnet-train.sh"; then
    pass "remote retention avoids deleting the bound launcher through a mutable path"
elif [ "$after_check_rc" -ne 0 ] && [ -s "$after_check_path_log" ] \
        && [ -s "$after_check_inode_log" ]; then
    after_check_victim=$(<"$after_check_path_log")
    after_check_inode=$(<"$after_check_inode_log")
    if [ -f "$after_check_victim" ] \
       && cmp -s "$remote_race_seed" "$after_check_victim" \
       && [ "$(/bin/ls -di "$after_check_victim" | awk '{print $1}')" \
          = "$after_check_inode" ]; then
        pass "remote retention fails closed and preserves an after-check replacement"
    else
        fail "remote retention removed the after-check replacement"
    fi
else
    fail "remote retention did not prove safe preservation or fail-closed replacement handling"
fi

launch_race_name=deploy-launcher-before-exec-symlink
launch_race_home="$fixture_root/$launch_race_name.remote-home"
launch_victim="$launch_race_home/victim-launcher.sh"
launch_victim_copy="$fixture_root/$launch_race_name.expected"
launch_marker="$fixture_root/$launch_race_name.executed"
launch_race_path_log="$fixture_root/$launch_race_name.race-path"
launch_race_inode_log="$fixture_root/$launch_race_name.race-inode"
mkdir -p "$launch_race_home/Projects/Odysseus/research/Odyssey"
cat > "$launch_victim" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' executed > "${ODYSSEUS_TEST_REMOTE_EXEC_MARKER:?}"
EOF
chmod +x "$launch_victim"
cp "$launch_victim" "$launch_victim_copy"
if run_operation "$launch_race_name" e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$launch_race_name" \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=0 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_RACE=launcher-before-exec-symlink \
    ODYSSEUS_TEST_REMOTE_VICTIM_FILE="$launch_victim" \
    ODYSSEUS_TEST_REMOTE_EXEC_MARKER="$launch_marker" \
    ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$launch_race_path_log" \
    ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$launch_race_inode_log"; then
    fail "deploy executed a launcher replacement after verified load"
elif [ ! -s "$launch_race_path_log" ] || [ ! -s "$launch_race_inode_log" ]; then
    fail "pre-execution launcher race fixture did not identify its victim"
elif [ -e "$launch_marker" ]; then
    fail "deploy executed the replacement launcher"
else
    launch_victim_inode=$(<"$launch_race_inode_log")
    if cmp -s "$launch_victim_copy" "$launch_victim" \
       && [ "$(/bin/ls -di "$launch_victim" | awk '{print $1}')" \
            = "$launch_victim_inode" ]; then
        pass "deploy revalidates the exact launcher before execution"
    else
        fail "deploy changed the rejected replacement launcher"
    fi
fi

helper_launch_race=deploy-helper-before-exec-inplace
helper_launch_home="$fixture_root/$helper_launch_race.remote-home"
helper_launch_marker="$fixture_root/$helper_launch_race.executed"
helper_launch_path_log="$fixture_root/$helper_launch_race.race-path"
helper_launch_inode_log="$fixture_root/$helper_launch_race.race-inode"
mkdir -p "$helper_launch_home/Projects/Odysseus/research/Odyssey"
if run_operation "$helper_launch_race" e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$helper_launch_race" \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=0 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_RACE=helper-before-exec-inplace \
    ODYSSEUS_TEST_REMOTE_EXEC_MARKER="$helper_launch_marker" \
    ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$helper_launch_path_log" \
    ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$helper_launch_inode_log"; then
    fail "deploy accepted same-inode mutation of its remote result helper"
elif [ ! -s "$helper_launch_path_log" ] \
     || [ ! -s "$helper_launch_inode_log" ]; then
    fail "remote helper mutation fixture did not identify its bound object"
elif [ -e "$helper_launch_marker" ]; then
    fail "deploy executed changed remote helper bytes"
else
    helper_launch_path=$(<"$helper_launch_path_log")
    helper_launch_inode=$(<"$helper_launch_inode_log")
    if [ -f "$helper_launch_path" ] \
       && [ "$(/bin/ls -di "$helper_launch_path" | awk '{print $1}')" \
          = "$helper_launch_inode" ]; then
        pass "deploy propagates the helper digest and rejects same-inode remote mutation"
    else
        fail "remote helper mutation changed the bound inode fixture"
    fi
fi

launcher_inplace_race=deploy-launcher-before-exec-inplace
launcher_inplace_home="$fixture_root/$launcher_inplace_race.remote-home"
launcher_inplace_marker="$fixture_root/$launcher_inplace_race.executed"
launcher_inplace_path_log="$fixture_root/$launcher_inplace_race.race-path"
launcher_inplace_inode_log="$fixture_root/$launcher_inplace_race.race-inode"
mkdir -p "$launcher_inplace_home/Projects/Odysseus/research/Odyssey"
if run_operation "$launcher_inplace_race" e2e/alexnet-deploy-fleet.sh env \
    FLEET=remote-one LOCAL_AS_BUILD=1 ALEXNET_RUN_ID="$launcher_inplace_race" \
    SKIP_BUILD=1 SKIP_DISTRIBUTE=0 SKIP_LAUNCH=0 \
    ALEXNET_DEPLOY_APPROVED_FLEET=remote-one \
    ODYSSEUS_TEST_EXEC_REMOTE_SHELL=1 \
    ODYSSEUS_TEST_REMOTE_RACE=launcher-before-exec-inplace \
    ODYSSEUS_TEST_REMOTE_EXEC_MARKER="$launcher_inplace_marker" \
    ODYSSEUS_TEST_REMOTE_RACE_PATH_LOG="$launcher_inplace_path_log" \
    ODYSSEUS_TEST_REMOTE_RACE_INODE_LOG="$launcher_inplace_inode_log"; then
    fail "deploy accepted same-inode mutation of its remote launcher"
elif [ -e "$launcher_inplace_marker" ]; then
    fail "deploy executed same-inode mutated launcher bytes"
elif [ -s "$launcher_inplace_path_log" ] \
     && [ -s "$launcher_inplace_inode_log" ]; then
    launcher_inplace_path=$(<"$launcher_inplace_path_log")
    launcher_inplace_inode=$(<"$launcher_inplace_inode_log")
    if [ -f "$launcher_inplace_path" ] \
       && [ "$(/bin/ls -di "$launcher_inplace_path" | awk '{print $1}')" \
          = "$launcher_inplace_inode" ]; then
        pass "deploy rejects same-inode remote launcher mutation before execution"
    else
        fail "same-inode launcher fixture changed identity"
    fi
else
    fail "same-inode launcher fixture did not identify its bound object"
fi

info "wait requires immutable container identity and current-run evidence"
wait_container_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if run_operation wait-nonzero e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run POLL_INTERVAL=1 \
    ODYSSEUS_TEST_PODMAN_STATE='exited 17'; then
    fail "wait accepted a non-zero container exit with completion evidence"
elif grep -Fq 'hub: exited 17' "$fixture_root/wait-nonzero.out" \
     && ! grep -Fq 'GATE PASSED' "$fixture_root/wait-nonzero.out"; then
    pass "wait preserves the non-zero container exit as terminal failure"
else
    fail "wait omitted the exact non-zero exit receipt"
fi

if run_operation wait-stale-weight e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run POLL_INTERVAL=1 \
    ODYSSEUS_TEST_PODMAN_STATE='exited 0'; then
    fail "wait accepted a weight that predates the current run"
elif grep -Fq 'weights=0' "$fixture_root/wait-stale-weight.out" \
     && ! grep -Fq 'GATE PASSED' "$fixture_root/wait-stale-weight.out"; then
    pass "wait rejects stale-only weights for the current run"
else
    fail "wait did not expose the stale current-run weight failure"
fi

printf '%s\n' current \
    > "$fixture_root/home/alexnet-results/runs/test-run/hub/alexnet_weights/current.bin"
touch -t 202201010000 \
    "$fixture_root/home/alexnet-results/runs/test-run/hub/alexnet_weights/current.bin"
if run_operation wait-zero e2e/alexnet-fleet-wait.sh env \
    FLEET=localhost ALEXNET_RUN_ID=test-run POLL_INTERVAL=1 \
    ODYSSEUS_TEST_PODMAN_STATE='exited 0'; then
    if grep -Fq 'localhost: exited 0' "$fixture_root/wait-zero.out" \
       && grep -Fq 'localhost: marker=present weights=1' \
           "$fixture_root/wait-zero.out" \
       && grep -Fxq "podman logs $wait_container_id" \
           "$fixture_root/wait-zero.effects" \
       && grep -Fq 'GATE PASSED' "$fixture_root/wait-zero.out"; then
        pass "wait reads marker evidence from the bound container ID"
    else
        fail "wait success omitted its exact current-run receipt"
    fi
else
    fail "wait rejected a successful current run with fresh evidence"
fi

if run_operation wait-large-log e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run ODYSSEUS_TEST_PODMAN_STATE='exited 0' \
    ODYSSEUS_TEST_LARGE_LOG_MIB=16 ODYSSEUS_TEST_MARKER_FIRST=1; then
    fail "wait accepted a completion log beyond its byte budget"
elif grep -Fq 'completion log exceeded' "$fixture_root/wait-large-log.out" \
     && ! grep -Fq 'GATE PASSED' "$fixture_root/wait-large-log.out"; then
    pass "wait rejects an over-budget log even when its marker appears first"
else
    fail "wait did not identify the over-budget completion log"
fi

if run_operation wait-stuck-log e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run ODYSSEUS_TEST_PODMAN_STATE='exited 0' \
    ODYSSEUS_TEST_STUCK_LOG=1 MARKER_RETRY_DELAY=0; then
    fail "wait accepted a stuck completion-log producer"
elif grep -q '^timeout .* podman logs ' "$fixture_root/wait-stuck-log.calls" \
     && ! grep -Fq 'GATE PASSED' "$fixture_root/wait-stuck-log.out"; then
    pass "wait bounds a stuck completion-log producer"
else
    fail "wait did not exercise the bounded stuck-log path"
fi

wait_race_marker="$fixture_root/wait-container-replaced.marker"
if run_operation wait-container-replaced e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run POLL_INTERVAL=1 \
    ODYSSEUS_TEST_PODMAN_STATE='exited 0' \
    ODYSSEUS_TEST_WAIT_REPLACEMENT_RACE=1 \
    ODYSSEUS_TEST_WAIT_RACE_MARKER="$wait_race_marker"; then
    fail "wait accepted completion evidence after the bound container was replaced"
elif grep -Fxq 'podman logs alexnet-training' \
     "$fixture_root/wait-container-replaced.effects"; then
    fail "wait read marker evidence from the replacement container name"
elif grep -Fq 'identity-failed' "$fixture_root/wait-container-replaced.out" \
     && ! grep -q '^podman logs ' \
        "$fixture_root/wait-container-replaced.effects"; then
    pass "wait rejects a replacement before reading marker evidence"
else
    fail "wait did not expose the bound-container replacement"
fi

if run_operation wait-bounded-sleep e2e/alexnet-fleet-wait.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run POLL_INTERVAL=600 \
    ODYSSEUS_TEST_CLOCK_MODE=near-deadline \
    ODYSSEUS_TEST_STATE_MODE=running-then-exited; then
    fail "wait accepted completion evidence after exhausting the fleet deadline"
elif grep -Fxq 'sleep 5' "$fixture_root/wait-bounded-sleep.calls" \
     && ! grep -Fxq 'sleep 600' "$fixture_root/wait-bounded-sleep.calls" \
     && grep -Fq 'deadline' "$fixture_root/wait-bounded-sleep.out"; then
    pass "wait caps poll sleep and refuses a log read after the fleet deadline"
else
    fail "wait did not enforce the remaining deadline across marker reads"
fi

for delay_case in \
    'POLL_INTERVAL=3601' \
    'SETTLE_SECONDS=61' \
    'MARKER_RETRY_DELAY=61'; do
    delay_name=${delay_case%%=*}
    delay_value=${delay_case#*=}
    case_name="wait-unbounded-$delay_name"
    if run_operation "$case_name" e2e/alexnet-fleet-wait.sh env \
        FLEET=hub ALEXNET_RUN_ID=test-run \
        "$delay_name=$delay_value"; then
        fail "wait accepted unbounded $delay_name"
    elif grep -q '^podman\|^ssh\|^rsync' \
         "$fixture_root/$case_name.effects"; then
        fail "invalid $delay_name reached a target operation"
    elif grep -Fq "$delay_name" "$fixture_root/$case_name.out"; then
        pass "wait rejects unbounded $delay_name before target operations"
    else
        fail "wait did not identify unbounded $delay_name"
    fi
done

info "collection never accepts stale or partial output"
legacy_source="$fixture_root/home/alexnet-results/hub"
mkdir -p "$legacy_source"
printf '%s\n' '=== AlexNet Training on hub ===' > "$legacy_source/training.log"
old_source_root="$fixture_root/old-source-results"
if run_operation collect-old-source e2e/alexnet-collect-results.sh env \
    FLEET=hub ALEXNET_RUN_ID=missing-current-run \
    CENTRAL_DIR="$old_source_root"; then
    fail "collect published a prior-run source for a missing current run"
elif [ -e "$old_source_root/hub" ]; then
    fail "collect published old source data into the current artifact tree"
elif grep -Fq 'current run' "$fixture_root/collect-old-source.out"; then
    pass "collect rejects prior-run source data for the current invocation"
else
    fail "collect did not identify the missing current-run source"
fi

stale_root="$fixture_root/stale-results"
mkdir -p "$stale_root/remote-one"
printf '%s\n' stale > "$stale_root/remote-one/stale.txt"
if run_operation collect-stale e2e/alexnet-collect-results.sh env \
    FLEET=remote-one CENTRAL_DIR="$stale_root"; then
    fail "collect accepted a stale per-host destination"
elif grep -q '^rsync ' "$fixture_root/collect-stale.effects"; then
    fail "collect transferred data into a stale destination"
elif grep -Fq 'already exists' "$fixture_root/collect-stale.out"; then
    pass "collect refuses stale output before transfer"
else
    fail "collect did not identify the stale destination"
fi

malicious_source="$fixture_root/home/alexnet-results/runs/test-run/hub"
ln -s "$fixture_root/secret-outside-results" "$malicious_source/outside-link"
ln -s "$fixture_root/secret-outside-results" "$legacy_source/outside-link"
malicious_root="$fixture_root/malicious-results"
if run_operation collect-malicious-link e2e/alexnet-collect-results.sh env \
    FLEET=hub ALEXNET_RUN_ID=test-run CENTRAL_DIR="$malicious_root"; then
    fail "collect published an untrusted symbolic link"
elif [ -L "$malicious_root/hub/outside-link" ]; then
    fail "collect left a symbolic link in the published artifact tree"
elif grep -Fq 'unsupported result-tree node' \
     "$fixture_root/collect-malicious-link.out"; then
    pass "collect rejects symbolic links before artifact publication"
else
    fail "collect did not report the unsafe result-tree node"
fi
rm "$malicious_source/outside-link"
rm "$legacy_source/outside-link"

wrong_run_source="$fixture_root/home/alexnet-results/runs/wrong-header/hub"
mkdir -p "$wrong_run_source"
{
    printf '%s\n' '=== AlexNet Training on hub ==='
    printf '%s\n' 'Run ID:   earlier-run'
} > "$wrong_run_source/training.log"
wrong_run_root="$fixture_root/wrong-run-results"
if run_operation collect-wrong-run-header e2e/alexnet-collect-results.sh env \
    FLEET=hub ALEXNET_RUN_ID=wrong-header CENTRAL_DIR="$wrong_run_root"; then
    fail "collect published a source whose launch header names another run"
elif [ -e "$wrong_run_root/hub" ]; then
    fail "collect published a mismatched run under the requested run identity"
elif grep -Fq 'current run source preflight failed' \
     "$fixture_root/collect-wrong-run-header.out"; then
    pass "collect binds source output to the exact run named by its launch header"
else
    fail "collect did not report the mismatched run launch header"
fi

ln -s old-run "$fixture_root/home/alexnet-results/runs/symlink-run"
symlink_root="$fixture_root/symlink-root-results"
if run_operation collect-symlink-root e2e/alexnet-collect-results.sh env \
    FLEET=hub ALEXNET_RUN_ID=symlink-run CENTRAL_DIR="$symlink_root"; then
    fail "collect followed a symbolic-link current-run root"
elif [ -e "$symlink_root/hub" ]; then
    fail "collect published data reached through a symbolic-link run root"
elif grep -Fq 'current run source preflight failed' \
     "$fixture_root/collect-symlink-root.out"; then
    pass "collect rejects a symbolic-link current-run root"
else
    fail "collect did not report the symbolic-link run root"
fi

partial_root="$fixture_root/partial-results"
if run_operation collect-partial e2e/alexnet-collect-results.sh env \
    FLEET='remote-one remote-two' ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$partial_root" \
    ODYSSEUS_TEST_RSYNC_FAIL_IP=192.0.2.12; then
    fail "partial fleet collection reported success"
elif [ "$(grep -c '^rsync ' "$fixture_root/collect-partial.effects")" -ne 2 ]; then
    fail "collect did not inspect every parallel transfer result"
elif [ ! -f "$partial_root/remote-one/training.log" ] \
     || [ -e "$partial_root/remote-two" ]; then
    fail "collect did not preserve only the verified fresh partial result"
elif ! grep -Fxq 'remote-one: transfer verified' "$fixture_root/collect-partial.out" \
     || ! grep -Fq 'remote-two: transfer failed' "$fixture_root/collect-partial.out"; then
    fail "collect omitted a per-target transfer receipt"
elif grep -Fq 'Collection verified' "$fixture_root/collect-partial.out"; then
    fail "partial collection emitted terminal completion"
else
    pass "collect preserves fresh forensic output but fails the partial fleet"
fi

race_root="$fixture_root/transfer-race-results"
if run_operation collect-transfer-race e2e/alexnet-collect-results.sh env \
    FLEET='remote-one remote-two' ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$race_root" \
    ODYSSEUS_TEST_RSYNC_STRIP_HEADER_IP=192.0.2.12; then
    fail "collect accepted a result whose launch header changed after preflight"
elif [ "$(grep -c '^rsync ' "$fixture_root/collect-transfer-race.effects")" -ne 2 ]; then
    fail "collect did not inspect every transfer after the source race"
elif [ ! -f "$race_root/remote-one/training.log" ] \
     || [ -e "$race_root/remote-two" ]; then
    fail "collect did not publish only the destination with a current-run launch header"
elif ! grep -Fq 'remote-one: transfer verified' \
         "$fixture_root/collect-transfer-race.out" \
     || ! grep -Fq 'remote-two: transfer failed' \
         "$fixture_root/collect-transfer-race.out"; then
    fail "collect omitted the destination validation receipt after the source race"
elif grep -Fq 'Collection transfer verified' \
     "$fixture_root/collect-transfer-race.out"; then
    fail "source race emitted terminal collection success"
else
    pass "collect validates copied launch headers and preserves only verified forensic output"
fi

hardlink_victim="$fixture_root/collect-hardlink-victim.txt"
hardlink_victim_copy="$fixture_root/collect-hardlink-victim.expected"
printf '%s\n' 'retained hardlink victim' > "$hardlink_victim"
cp "$hardlink_victim" "$hardlink_victim_copy"
hardlink_victim_inode=$(/bin/ls -di "$hardlink_victim" | awk '{print $1}')
hardlink_root="$fixture_root/hardlink-results"
if run_operation collect-hardlink-race e2e/alexnet-collect-results.sh env \
    FLEET=remote-one ALEXNET_RUN_ID=test-run CENTRAL_DIR="$hardlink_root" \
    ODYSSEUS_TEST_COLLECT_HARDLINK_VICTIM="$hardlink_victim"; then
    fail "collect published a hardlink injected after transfer"
elif ! cmp -s "$hardlink_victim_copy" "$hardlink_victim" \
     || [ "$(/bin/ls -di "$hardlink_victim" | awk '{print $1}')" \
        != "$hardlink_victim_inode" ]; then
    fail "collect changed the hardlink victim while rejecting publication"
elif [ -e "$hardlink_root/remote-one/injected-hardlink" ]; then
    fail "collect retained the injected hardlink in published output"
else
    pass "collect rejects a raced hardlink and preserves its victim"
fi

collect_race_parent="$fixture_root/collect-parent-race"
collect_race_held="$fixture_root/collect-parent-race-held"
collect_race_victim="$fixture_root/collect-parent-race-victim"
collect_race_decoy_log="$fixture_root/collect-parent-race-decoy"
mkdir -p "$collect_race_parent" "$collect_race_victim"
collect_race_sentinel="$collect_race_victim/sentinel.txt"
collect_race_sentinel_copy="$fixture_root/collect-parent-race.expected"
printf '%s\n' 'retained ancestor victim' > "$collect_race_sentinel"
cp "$collect_race_sentinel" "$collect_race_sentinel_copy"
collect_race_sentinel_inode=$(
    /bin/ls -di "$collect_race_sentinel" | awk '{print $1}'
)
if run_operation collect-parent-race e2e/alexnet-collect-results.sh env \
    FLEET=remote-one ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$collect_race_parent/published" \
    ODYSSEUS_TEST_COLLECT_PARENT_RACE=1 \
    ODYSSEUS_TEST_COLLECT_PARENT="$collect_race_parent" \
    ODYSSEUS_TEST_COLLECT_HELD_PARENT="$collect_race_held" \
    ODYSSEUS_TEST_COLLECT_VICTIM_PARENT="$collect_race_victim" \
    ODYSSEUS_TEST_COLLECT_RACE_DECOY_LOG="$collect_race_decoy_log"; then
    fail "collect accepted a replaced publication parent"
else
    collect_race_decoy=$(<"$collect_race_decoy_log")
    if cmp -s "$collect_race_sentinel_copy" "$collect_race_sentinel" \
       && [ "$(/bin/ls -di "$collect_race_sentinel" | awk '{print $1}')" \
          = "$collect_race_sentinel_inode" ] \
       && [ -f "$collect_race_decoy/victim.txt" ] \
       && [ ! -e "$collect_race_victim/published" ]; then
        pass "collect cleanup and publication preserve a replaced ancestor"
    else
        fail "collect cleanup or publication changed the replaced ancestor victim"
    fi
fi

success_root="$fixture_root/success-results"
if run_operation collect-success e2e/alexnet-collect-results.sh env \
    FLEET='hub remote-one remote-two' ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$success_root"; then
    if grep -Fq "hub: collected -> $success_root/hub" \
       "$fixture_root/collect-success.out" \
       && grep -Fq "remote-one: collected -> $success_root/remote-one" \
       "$fixture_root/collect-success.out" \
       && grep -Fq "remote-two: collected -> $success_root/remote-two" \
       "$fixture_root/collect-success.out" \
       && [ -f "$success_root/hub/training.log" ] \
       && grep -Fq 192.0.2.11 "$success_root/remote-one/training.log" \
       && grep -Fq 192.0.2.12 "$success_root/remote-two/training.log" \
       && grep -Fq 'hub: files=' "$fixture_root/collect-success.out" \
       && grep -Fq 'launch-header=present' \
           "$fixture_root/collect-success.out" \
       && ! grep -Fq 'training-log-marker=' \
           "$fixture_root/collect-success.out"; then
        pass "collection publishes one exact receipt for every requested host"
    else
        fail "successful collection omitted a host receipt or result"
    fi
else
    fail "complete fleet collection failed"
fi

info "per-host training launch fails closed and preserves prior runs"
assert_train_input_rejected() {
    local case_name=$1
    local input_name=$2
    local input_value=$3
    local forbidden_path=${4:-}
    local default_result="$fixture_root/home/alexnet-results/runs/$case_name"

    if run_train "$case_name" env \
        IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID="$case_name" \
        "$input_name=$input_value"; then
        fail "train accepted invalid $input_name"
    elif grep -Eq '^(podman|ssh|rsync) ' \
         "$fixture_root/$case_name.effects"; then
        fail "invalid $input_name reached a target operation"
    elif [ -e "$default_result" ] || [ -L "$default_result" ]; then
        fail "invalid $input_name created a result tree"
    elif [ -n "$forbidden_path" ] \
         && { [ -e "$forbidden_path" ] || [ -L "$forbidden_path" ]; }; then
        fail "invalid $input_name caused a forbidden filesystem effect"
    elif grep -Fq "ERROR: $input_name" "$fixture_root/$case_name.out"; then
        pass "train rejects invalid $input_name before effects"
    else
        fail "train omitted the invalid $input_name diagnostic"
    fi
}

max_batches_sentinel="$fixture_root/max-batches-evaluated"
# The literal command substitution is hostile input for the launcher.
# shellcheck disable=SC2016
malicious_max_batches='index[$(touch '"$max_batches_sentinel"')]'
assert_train_input_rejected train-hostile-max-batches MAX_BATCHES \
    "$malicious_max_batches" "$max_batches_sentinel"

while IFS='|' read -r input_case input_name input_value; do
    [ -n "$input_case" ] || continue
    assert_train_input_rejected "$input_case" "$input_name" "$input_value"
done <<'EOF'
train-invalid-epochs|EPOCHS|1+1
train-invalid-batch-size|BATCH_SIZE|0
train-invalid-learning-rate|LEARNING_RATE|nan
train-invalid-precision|PRECISION|fp64
train-invalid-max-batches|MAX_BATCHES|-1
train-invalid-smoke|SMOKE|yes
train-invalid-force-avx2|FORCE_AVX2|yes
train-invalid-memory|MEM_LIMIT|--privileged
train-invalid-cpus|CPU_LIMIT|--privileged
train-invalid-shm|SHM_SIZE|--privileged
train-invalid-image|IMAGE_NAME|--privileged
train-invalid-run-id|ALEXNET_RUN_ID|../escape
EOF

invalid_workspace="$fixture_root/workspace:escape"
assert_train_input_rejected train-invalid-workspace WORKSPACE_DIR \
    "$invalid_workspace" "$invalid_workspace"
invalid_results="$fixture_root/results:escape"
assert_train_input_rejected train-invalid-results RESULTS_DIR \
    "$invalid_results" "$invalid_results"

info "result helpers remain bound when their regular pathname is replaced"
train_helper_support="$fixture_root/train-helper-support"
mkdir -p "$train_helper_support"
cp "$ROOT/e2e/alexnet-collect-fs.py" \
    "$train_helper_support/alexnet-collect-fs.py"
if run_train helper-swap-train env \
    ALEXNET_SUPPORT_DIR="$train_helper_support" \
    ALEXNET_RUN_ID=helper-swap-train \
    ODYSSEUS_TEST_HELPER_SWAP_SOURCE="$train_helper_support/alexnet-collect-fs.py" \
    ODYSSEUS_TEST_HELPER_SWAP_ACTION=train-create \
    ODYSSEUS_TEST_HELPER_SWAP_DONE="$fixture_root/train-helper-swap.done" \
    ODYSSEUS_TEST_HELPER_SWAP_HELD="$fixture_root/train-helper-swap.held" \
    ODYSSEUS_TEST_HELPER_SWAP_EXECUTED="$fixture_root/train-helper-swap.executed"; then
    if [ -f "$fixture_root/train-helper-swap.done" ] \
       && [ ! -e "$fixture_root/train-helper-swap.executed" ]; then
        pass "train executes the helper object bound before pathname replacement"
    else
        fail "train did not exercise or contain the helper replacement"
    fi
else
    fail "train reopened a replaced result helper pathname"
fi

collect_helper_support="$fixture_root/collect-helper-support"
mkdir -p "$collect_helper_support"
cp "$ROOT/e2e/alexnet-collect-results.sh" "$collect_helper_support/"
cp "$ROOT/e2e/alexnet-collect-fs.py" "$collect_helper_support/"
if run_operation helper-swap-collect \
    "$collect_helper_support/alexnet-collect-results.sh" env \
    FLEET=hub ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$fixture_root/helper-swap-collect-results" \
    ODYSSEUS_TEST_HELPER_SWAP_SOURCE="$collect_helper_support/alexnet-collect-fs.py" \
    ODYSSEUS_TEST_HELPER_SWAP_ACTION=prepare \
    ODYSSEUS_TEST_HELPER_SWAP_DONE="$fixture_root/collect-helper-swap.done" \
    ODYSSEUS_TEST_HELPER_SWAP_HELD="$fixture_root/collect-helper-swap.held" \
    ODYSSEUS_TEST_HELPER_SWAP_EXECUTED="$fixture_root/collect-helper-swap.executed"; then
    if [ -f "$fixture_root/collect-helper-swap.done" ] \
       && [ ! -e "$fixture_root/collect-helper-swap.executed" ]; then
        pass "collect executes the helper object bound before pathname replacement"
    else
        fail "collect did not exercise or contain the helper replacement"
    fi
else
    fail "collect reopened a replaced result helper pathname"
fi

train_inplace_support="$fixture_root/train-helper-inplace-support"
mkdir -p "$train_inplace_support"
cp "$ROOT/e2e/alexnet-collect-fs.py" \
    "$train_inplace_support/alexnet-collect-fs.py"
train_inplace_inode=$(/bin/ls -di \
    "$train_inplace_support/alexnet-collect-fs.py" | awk '{print $1}')
if run_train helper-inplace-train env \
    ALEXNET_SUPPORT_DIR="$train_inplace_support" \
    ALEXNET_RUN_ID=helper-inplace-train \
    ODYSSEUS_TEST_HELPER_INPLACE_SOURCE="$train_inplace_support/alexnet-collect-fs.py" \
    ODYSSEUS_TEST_HELPER_INPLACE_ACTION=train-create \
    ODYSSEUS_TEST_HELPER_INPLACE_DONE="$fixture_root/train-helper-inplace.done" \
    ODYSSEUS_TEST_HELPER_INPLACE_EXECUTED="$fixture_root/train-helper-inplace.executed"; then
    fail "train accepted same-inode helper content mutation"
elif [ -f "$fixture_root/train-helper-inplace.done" ] \
     && [ ! -e "$fixture_root/train-helper-inplace.executed" ] \
     && [ "$(/bin/ls -di "$train_inplace_support/alexnet-collect-fs.py" | awk '{print $1}')" \
        = "$train_inplace_inode" ]; then
    pass "train rejects same-inode helper mutation before executing changed bytes"
else
    fail "train executed or replaced the same-inode helper mutation fixture"
fi

collect_inplace_support="$fixture_root/collect-helper-inplace-support"
mkdir -p "$collect_inplace_support"
cp "$ROOT/e2e/alexnet-collect-results.sh" "$collect_inplace_support/"
cp "$ROOT/e2e/alexnet-collect-fs.py" "$collect_inplace_support/"
collect_inplace_inode=$(/bin/ls -di \
    "$collect_inplace_support/alexnet-collect-fs.py" | awk '{print $1}')
if run_operation helper-inplace-collect \
    "$collect_inplace_support/alexnet-collect-results.sh" env \
    FLEET=hub ALEXNET_RUN_ID=test-run \
    CENTRAL_DIR="$fixture_root/helper-inplace-collect-results" \
    ODYSSEUS_TEST_HELPER_INPLACE_SOURCE="$collect_inplace_support/alexnet-collect-fs.py" \
    ODYSSEUS_TEST_HELPER_INPLACE_ACTION=prepare \
    ODYSSEUS_TEST_HELPER_INPLACE_DONE="$fixture_root/collect-helper-inplace.done" \
    ODYSSEUS_TEST_HELPER_INPLACE_EXECUTED="$fixture_root/collect-helper-inplace.executed"; then
    fail "collect accepted same-inode helper content mutation"
elif [ -f "$fixture_root/collect-helper-inplace.done" ] \
     && [ ! -e "$fixture_root/collect-helper-inplace.executed" ] \
     && [ "$(/bin/ls -di "$collect_inplace_support/alexnet-collect-fs.py" | awk '{print $1}')" \
        = "$collect_inplace_inode" ]; then
    pass "collect rejects same-inode helper mutation before executing changed bytes"
else
    fail "collect executed or replaced the same-inode helper mutation fixture"
fi

if run_train train-image-regex env \
    IMAGE_NAME='odyssey.dev:custom' \
    ODYSSEUS_TEST_IMAGE_LIST='odysseyXdev:custom' \
    ALEXNET_RUN_ID=image-regex; then
    fail "train accepted a regex-only image-name match"
elif ! grep -q '^podman run -d' "$fixture_root/train-image-regex.effects" \
     && grep -Fq "Image 'odyssey.dev:custom' not loaded" \
         "$fixture_root/train-image-regex.out"; then
    pass "train requires an exact image identity"
else
    fail "train image mismatch did not fail before launch"
fi

if run_train train-missing-image env \
    IMAGE_NAME='odyssey:missing' ODYSSEUS_TEST_IMAGE_LIST='' \
    ALEXNET_RUN_ID=missing-image; then
    fail "train accepted an absent image"
elif grep -Fq 'just alexnet-fleet-deploy' \
     "$fixture_root/train-missing-image.out" \
     && ! grep -Fq '/tmp/odyssey-dev.tar' \
         "$fixture_root/train-missing-image.out"; then
    pass "missing-image guidance uses the canonical deployment entry point"
else
    fail "missing-image guidance advertises a stale archive procedure"
fi

bound_image_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
if run_train train-image-replacement-race env \
    IMAGE_NAME=odyssey:dev ODYSSEUS_TEST_IMAGE_ID="$bound_image_id" \
    ALEXNET_RUN_ID=image-replacement-race; then
    if grep -Fq " $bound_image_id bash -c " \
           "$fixture_root/train-image-replacement-race.effects" \
       && ! grep -Fq ' odyssey:dev bash -c ' \
           "$fixture_root/train-image-replacement-race.effects"; then
        pass "train launches the immutable image identity bound before mutation"
    else
        fail "train launched through a mutable image tag after identity binding"
    fi
else
    fail "train rejected the valid immutable image identity"
fi

publication_results="$fixture_root/train-publication-results"
publication_held="$fixture_root/train-publication-held"
publication_victim="$fixture_root/train-publication-victim"
publication_victim_log="$publication_victim/publication-race/hub/training.log"
publication_victim_copy="$fixture_root/train-publication-victim.expected"
mkdir -p "$(dirname "$publication_victim_log")"
printf '%s\n' 'retained publication victim' > "$publication_victim_log"
cp "$publication_victim_log" "$publication_victim_copy"
publication_victim_inode=$(
    /bin/ls -di "$publication_victim_log" | awk '{print $1}'
)
if run_train train-result-publication-race env \
    IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID=publication-race \
    RESULTS_DIR="$publication_results" \
    ODYSSEUS_TEST_TRAIN_PUBLICATION_RACE=1 \
    ODYSSEUS_TEST_TRAIN_RESULTS_ROOT="$publication_results" \
    ODYSSEUS_TEST_TRAIN_HELD_ROOT="$publication_held" \
    ODYSSEUS_TEST_TRAIN_VICTIM_ROOT="$publication_victim"; then
    fail "train published through a replaced result ancestor"
elif ! cmp -s "$publication_victim_copy" "$publication_victim_log" \
     || [ "$(/bin/ls -di "$publication_victim_log" | awk '{print $1}')" \
        != "$publication_victim_inode" ]; then
    fail "train changed the result publication victim"
elif grep -q '^podman run -d' \
     "$fixture_root/train-result-publication-race.effects"; then
    fail "train launched after its result publication binding changed"
else
    pass "train rejects a replaced publication ancestor and preserves its victim"
fi

mount_results="$fixture_root/train-mount-results"
mount_held="$fixture_root/train-mount-held"
mount_victim="$fixture_root/train-mount-victim"
mount_victim_result="$mount_victim/mount-race/hub"
mkdir -p "$mount_victim_result"
if run_train train-result-mount-race env \
    IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID=mount-race \
    RESULTS_DIR="$mount_results" \
    ODYSSEUS_TEST_TRAIN_MOUNT_RACE=1 \
    ODYSSEUS_TEST_TRAIN_RESULTS_ROOT="$mount_results" \
    ODYSSEUS_TEST_TRAIN_HELD_ROOT="$mount_held" \
    ODYSSEUS_TEST_TRAIN_VICTIM_ROOT="$mount_victim"; then
    fail "train accepted a changed result binding after container launch"
elif [ ! -e "$mount_victim_result/container-result.txt" ] \
     && grep -Eq ' -v /(?:proc/[0-9]+|dev)/fd/[0-9]+:/results:Z ' \
         "$fixture_root/train-result-mount-race.effects"; then
    pass "train binds the result mount and reports an ancestor replacement"
else
    fail "train mounted or wrote through a replaced result ancestor"
fi

for unsafe_status in exists-fail inspect-fail running paused restarting; do
    case_name="train-existing-$unsafe_status"
    if run_train "$case_name" env \
        IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID="$case_name" \
        ODYSSEUS_TEST_CONTAINER_MODE="$unsafe_status"; then
        fail "train replaced a container after status '$unsafe_status'"
    elif grep -q '^podman rm -f alexnet-training' \
         "$fixture_root/$case_name.effects"; then
        fail "train removed a container after status '$unsafe_status'"
    elif grep -Fq 'cannot safely replace' "$fixture_root/$case_name.out"; then
        pass "train fails closed for existing status '$unsafe_status'"
    else
        fail "train omitted the fail-closed status diagnostic for '$unsafe_status'"
    fi
done

for retained_status in exited created; do
    case_name="train-retained-$retained_status"
    if run_train "$case_name" env \
        IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID="$case_name" \
        ODYSSEUS_TEST_CONTAINER_MODE="$retained_status"; then
        fail "train replaced an existing container in status '$retained_status'"
    elif grep -Eq '^podman (rm -f|run -d)' \
         "$fixture_root/$case_name.effects"; then
        fail "train changed an existing container in status '$retained_status'"
    elif grep -Fq 'separately authorized cleanup' \
         "$fixture_root/$case_name.out"; then
        pass "train retains an existing container in status '$retained_status'"
    else
        fail "train omitted cleanup guidance for retained status '$retained_status'"
    fi
done

historical="$fixture_root/home/alexnet-results/runs/old-run/hub/training.log"
mkdir -p "$(dirname "$historical")"
printf '%s\n' 'historical evidence' > "$historical"
if run_train train-new-run env \
    IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID=new-run; then
    new_log="$fixture_root/home/alexnet-results/runs/new-run/hub/training.log"
    if grep -Fxq 'historical evidence' "$historical" \
       && [ -f "$new_log" ] \
       && grep -Fq 'Run ID:   new-run' "$new_log" \
       && grep -Fq "FLEET='hub' ALEXNET_RUN_ID='new-run' just alexnet-fleet-collect" \
           "$fixture_root/train-new-run.out"; then
        pass "train isolates the new run and preserves historical evidence"
    else
        fail "train did not create a run-specific result tree"
    fi
else
    fail "train could not launch into a new run-specific result tree"
fi

if run_train train-exact-id-replaced env \
    IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID=train-exact-id-replaced \
    ODYSSEUS_TEST_TRAIN_EXACT_REPLACED=1; then
    fail "train adopted a same-name replacement after container creation"
elif grep -Fxq \
       'podman inspect aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --format {{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
       "$fixture_root/train-exact-id-replaced.effects" \
     && grep -Fq 'exact created training container is unavailable' \
       "$fixture_root/train-exact-id-replaced.out"; then
    pass "train never adopts a same-name replacement for its exact run receipt"
else
    fail "train did not fail on loss of its exact created container"
fi

if run_train train-reused-run env \
    IMAGE_NAME=odyssey:dev ALEXNET_RUN_ID=new-run \
    ODYSSEUS_TEST_CONTAINER_MODE=exited; then
    fail "train reused an existing run result directory"
elif grep -Eq '^podman (rm -f|run -d)' \
     "$fixture_root/train-reused-run.effects"; then
    fail "reused run identity changed the retained container or launched a replacement"
elif grep -Fq 'result directory already exists' \
     "$fixture_root/train-reused-run.out" \
     && grep -Fxq 'historical evidence' "$historical"; then
    pass "train rejects run-ID reuse without changing historical evidence"
else
    fail "train did not preserve the existing run after identity reuse"
fi

info "chaos orchestration has exact local authority and current-run gate identity"
chaos_root="$fixture_root/chaos"
mkdir -p "$chaos_root/e2e"
cp "$ROOT/e2e/alexnet-mesh-chaos.sh" "$chaos_root/e2e/"
for helper in alexnet-fleet-teardown.sh alexnet-deploy-fleet.sh; do
    cat > "$chaos_root/e2e/$helper" <<'EOF'
#!/usr/bin/env bash
printf '%s fleet=%s approval=%s deploy_approval=%s dry=%s run=%s results=%s\n' \
    "$(basename "$0")" "${FLEET:-}" \
    "${ALEXNET_TEARDOWN_APPROVED_FLEET:-}" \
    "${ALEXNET_DEPLOY_APPROVED_FLEET:-}" "${DRY_RUN:-}" \
    "${ALEXNET_RUN_ID:-}" \
    "${RESULTS_DIR:-}" \
    >> "${ODYSSEUS_TEST_CHAOS_LOG:?}"
case "$(basename "$0")" in
    alexnet-fleet-teardown.sh)
        teardown_rc=0
        if [ "${FLEET:-}" = hermes ]; then
            teardown_rc=${ODYSSEUS_TEST_CHAOS_TEARDOWN_RC:-0}
        fi
        if [ "$teardown_rc" != 0 ]; then
            printf '%s\n' 'ERROR: fleet resolution is incomplete' >&2
        fi
        exit "$teardown_rc"
        ;;
    *)
        if [ "${FLEET:-}" = "hub no-such-host-xyz" ] \
                && { [ "${DRY_RUN:-}" != 1 ] \
                    || [ -n "${ALEXNET_DEPLOY_APPROVED_FLEET:-}" ]; }; then
            printf '%s\n' 'ERROR: C2 did not reach safe dry-run resolution' >&2
            exit 64
        fi
        if [ "${ODYSSEUS_TEST_CHAOS_DEPLOY_RC:-1}" != 0 ]; then
            printf '%s\n' 'ERROR: fleet resolution is incomplete' >&2
        fi
        exit "${ODYSSEUS_TEST_CHAOS_DEPLOY_RC:-1}"
        ;;
esac
EOF
done
cat > "$chaos_root/e2e/alexnet-train.sh" <<'EOF'
#!/usr/bin/env bash
printf 'train run=%s\n' "${ALEXNET_RUN_ID:-}" >> "${ODYSSEUS_TEST_CHAOS_LOG:?}"
case "${ALEXNET_RUN_ID:-}" in
    *-c4)
        printf '%s\n' "ERROR: cannot safely replace 'alexnet-training': verified status 'running'." >&2
        exit 1
        ;;
    *-c5)
        c5_launch_rc=${ODYSSEUS_TEST_CHAOS_C5_LAUNCH_RC:-0}
        c5_results="$HOME/alexnet-results/runs/$ALEXNET_RUN_ID/$(hostname)"
        if [ "$c5_launch_rc" != 0 ]; then
            if [ "${ODYSSEUS_TEST_CHAOS_C5_CREATE_RESULTS_BEFORE_FAIL:-0}" = 1 ]; then
                mkdir -p "$c5_results"
                printf '%s\n' 'partial launch output' > "$c5_results/training.log"
            fi
            printf '%s\n' 'ERROR: controlled C5 launch failure' >&2
        else
            mkdir -p "$c5_results"
            printf 'Run ID:   %s\n' "$ALEXNET_RUN_ID" \
                > "$c5_results/training.log"
            if [[ "${ALEXNET_CONTAINER_ID_FD:-}" =~ ^[0-9]+$ ]]; then
                printf '%s\n' \
                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                    >&"$ALEXNET_CONTAINER_ID_FD"
                if [ "${ODYSSEUS_TEST_CHAOS_RETARGET_CIDFILE:-0}" = 1 ]; then
                    receipt_path=$(/usr/sbin/lsof -a -p $$ \
                        -d "$ALEXNET_CONTAINER_ID_FD" -Fn \
                        | sed -n 's/^n//p' | head -1)
                    if [ -n "$receipt_path" ]; then
                        /bin/mv -- "$receipt_path" "$receipt_path.held"
                        printf '%s\n' \
                            eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
                            > "$receipt_path"
                    fi
                fi
            fi
            printf '%s|%s|%s\n' "$ALEXNET_RUN_ID" \
                "${ODYSSEUS_TEST_IMAGE_ID:-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                > "${ODYSSEUS_TEST_CHAOS_BINDING_FILE:?}"
        fi
        exit "$c5_launch_rc"
        ;;
    *)
        printf '%s\n' "ERROR: Image '${IMAGE_NAME:-}' not loaded" >&2
        exit 1
        ;;
esac
EOF
cat > "$chaos_root/e2e/alexnet-fleet-wait.sh" <<'EOF'
#!/usr/bin/env bash
printf 'wait run=%s args=%s\n' "${ALEXNET_RUN_ID:-}" "$*" \
    >> "${ODYSSEUS_TEST_CHAOS_LOG:?}"
case "${ALEXNET_RUN_ID:-}" in
    *-c5)
        printf '%s\n' '1 container(s) exited non-zero'
        exit 1
        ;;
    *-c6)
        if [ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6:-0}" = 1 ]; then
            kill -TERM "$PPID"
            exit 143
        fi
        ;;
esac
case " $* " in
    *' --smoke '*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$chaos_root/e2e"/*.sh

run_chaos_case() {
    local case_name=$1
    shift
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$fixture_root/$case_name.log"
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/$case_name.log" \
    ODYSSEUS_TEST_CHAOS_BINDING_FILE="$fixture_root/$case_name.binding" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
        "$@" bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
        > "$fixture_root/$case_name.out" 2>&1
}

run_chaos_case_bounded() {
    local case_name=$1
    shift
    : > "$fixture_root/$case_name.calls"
    : > "$fixture_root/$case_name.effects"
    : > "$fixture_root/$case_name.log"
    ODYSSEUS_TEST_CALL_LOG="$fixture_root/$case_name.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/$case_name.log" \
    ODYSSEUS_TEST_CHAOS_BINDING_FILE="$fixture_root/$case_name.binding" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
        "$real_python" -I -E - "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
            "$@" > "$fixture_root/$case_name.out" 2>&1 <<'PY'
import os
import signal
import subprocess
import sys

script, *prefix = sys.argv[1:]
process = subprocess.Popen(
    [*prefix, "/bin/bash", script],
    env=os.environ.copy(),
    start_new_session=True,
)
try:
    raise SystemExit(process.wait(timeout=15))
except subprocess.TimeoutExpired:
    try:
        listing = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid="], text=True
        )
    except (OSError, subprocess.SubprocessError):
        listing = ""
    children = {}
    for line in listing.splitlines():
        try:
            child, parent = map(int, line.split())
        except ValueError:
            continue
        children.setdefault(parent, []).append(child)
    pending = list(children.get(process.pid, ()))
    descendants = []
    while pending:
        child = pending.pop()
        descendants.append(child)
        pending.extend(children.get(child, ()))
    for child in reversed(descendants):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait()
    print("chaos case exceeded its 15-second test bound", file=sys.stderr)
    raise SystemExit(124)
PY
}

chaos_temp_wrapper="$fixture_root/chaos-temp-wrapper.sh"
cat > "$chaos_temp_wrapper" <<'EOF'
#!/usr/bin/env bash
set -eu
predictable="/tmp/mesh-chaos-$$.out"
/bin/rm -f -- "$predictable"
printf '%s\n' 'retain secure-temp sentinel' > "${ODYSSEUS_TEST_CHAOS_SENTINEL:?}"
/bin/ln -s -- "$ODYSSEUS_TEST_CHAOS_SENTINEL" "$predictable"
printf '%s\n' "$predictable" > "${ODYSSEUS_TEST_CHAOS_PREDICTABLE_LOG:?}"
exec /bin/bash "${ODYSSEUS_TEST_CHAOS_SCRIPT:?}"
EOF
chmod +x "$chaos_temp_wrapper"
chaos_temp_sentinel="$fixture_root/chaos-temp.sentinel"
chaos_predictable_log="$fixture_root/chaos-temp.predictable"
chaos_secure_tmp="$fixture_root/chaos-secure-tmp"
mkdir -p "$chaos_secure_tmp"
: > "$fixture_root/chaos-secure-temp.calls"
: > "$fixture_root/chaos-secure-temp.effects"
: > "$fixture_root/chaos-secure-temp.log"
chaos_temp_rc=0
ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-secure-temp.calls" \
ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-secure-temp.effects" \
ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-secure-temp.log" \
ODYSSEUS_TEST_CHAOS_SENTINEL="$chaos_temp_sentinel" \
ODYSSEUS_TEST_CHAOS_PREDICTABLE_LOG="$chaos_predictable_log" \
ODYSSEUS_TEST_CHAOS_SCRIPT="$chaos_root/e2e/alexnet-mesh-chaos.sh" \
TMPDIR="$chaos_secure_tmp" HOME="$fixture_root/home" \
PATH="$fixture_bin:/usr/bin:/bin" ALEXNET_CHAOS_APPROVED_HOST=hub \
    bash "$chaos_temp_wrapper" \
    > "$fixture_root/chaos-secure-temp.out" 2>&1 || chaos_temp_rc=$?
chaos_predictable_path=$(<"$chaos_predictable_log")
if [ "$chaos_temp_rc" -eq 0 ] \
        && grep -Fxq 'retain secure-temp sentinel' "$chaos_temp_sentinel" \
        && [ -L "$chaos_predictable_path" ] \
        && [ "$(find "$chaos_secure_tmp" -mindepth 1 -maxdepth 1 \
            -name '.alexnet-quarantine-*' | wc -l | tr -d ' ')" -eq 2 ] \
        && [ -z "$(find "$chaos_secure_tmp" -mindepth 1 -maxdepth 1 \
            ! -name '.alexnet-quarantine-*' -print -quit)" ] \
        && [ -z "$(find "$chaos_secure_tmp" -type l -print -quit)" ]; then
    pass "chaos securely quarantines private temporary objects and preserves a predictable-path victim"
else
    fail "chaos used or retained an unsafe temporary output path"
fi
/bin/rm -f -- "$chaos_predictable_path"

: > "$fixture_root/chaos-unapproved.calls"
: > "$fixture_root/chaos-unapproved.effects"
: > "$fixture_root/chaos-unapproved.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-unapproved.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-unapproved.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-unapproved.log" \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-unapproved.out" 2>&1; then
    fail "chaos suite accepted missing exact-host authority"
elif [ -s "$fixture_root/chaos-unapproved.log" ] \
     || grep -Eq '^podman |^ssh |^rsync ' \
         "$fixture_root/chaos-unapproved.effects"; then
    fail "unapproved chaos reached a mutable boundary"
elif grep -Fq 'ALEXNET_CHAOS_APPROVED_HOST' \
     "$fixture_root/chaos-unapproved.out"; then
    pass "chaos suite stops before effects without exact local authority"
else
    fail "unapproved chaos omitted its exact-host approval route"
fi

: > "$fixture_root/chaos-timeout.calls"
: > "$fixture_root/chaos-timeout.effects"
: > "$fixture_root/chaos-timeout.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-timeout.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-timeout.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-timeout.log" \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_TIMEOUT=0 \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-timeout.out" 2>&1; then
    fail "chaos accepted a disabled timeout bound"
elif grep -Eq '^podman |^ssh |^rsync ' \
     "$fixture_root/chaos-timeout.effects"; then
    fail "invalid chaos timeout reached a mutable boundary"
elif grep -Fq 'CHAOS_TIMEOUT' "$fixture_root/chaos-timeout.out"; then
    pass "chaos rejects a disabled timeout before effects"
else
    fail "chaos did not identify the invalid timeout"
fi

: > "$fixture_root/chaos-approved.calls"
: > "$fixture_root/chaos-approved.effects"
: > "$fixture_root/chaos-approved.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-approved.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-approved.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-approved.log" \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-approved.out" 2>&1; then
    smoke_run=$(awk '/^wait run=.*--smoke/ { sub(/^wait run=/, ""); sub(/ args=.*/, ""); print; exit }' \
        "$fixture_root/chaos-approved.log")
    strict_run=$(awk '/^wait run=/ && $0 !~ /--smoke/ { sub(/^wait run=/, ""); sub(/ args=.*/, ""); print; exit }' \
        "$fixture_root/chaos-approved.log")
    teardown_count=$(grep -Fc \
        "alexnet-fleet-teardown.sh fleet=hub approval=hub deploy_approval= dry= run=$smoke_run results=.cache/odysseus-alexnet-chaos" \
        "$fixture_root/chaos-approved.log")
    if [[ "$smoke_run" =~ ^chaos-[A-Za-z0-9._-]+$ \
            && "$strict_run" == "$smoke_run" \
            && "$teardown_count" == 2 \
            && ! -s "$fixture_root/chaos-approved.calls" ]]; then
        pass "hermetic chaos binds one run, proves teardown idempotency, and avoids Tailscale"
    else
        fail "hermetic chaos did not preserve its run, idempotency, or offline contract"
    fi
else
    fail "approved hermetic chaos orchestration did not complete"
fi

live_state="$fixture_root/chaos-live.state"
if run_chaos_case chaos-live-success env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$live_state"; then
    if grep -Fq 'C4: clobber guard rejected the running fixture' \
           "$fixture_root/chaos-live-success.out" \
       && [ "$(grep -Ec '^podman inspect d{64} .*State.Status.*\.Image' \
            "$fixture_root/chaos-live-success.effects")" -ge 2 ] \
       && grep -Fq "C5: gate detected the killed container's non-zero exit" \
           "$fixture_root/chaos-live-success.out" \
       && grep -Eq '^podman kill [0-9a-f]{64}$' \
           "$fixture_root/chaos-live-success.effects" \
       && ! grep -Eq '^podman (kill|rm -f) alexnet-training$' \
           "$fixture_root/chaos-live-success.effects"; then
        pass "live chaos mutates only bound container identities"
    else
        fail "live chaos omitted C4 or C5 terminal evidence"
    fi
else
    fail "available live chaos could not complete C4 through C7"
fi

receipt_swap_env="$fixture_root/chaos-receipt-swap.bash"
cat > "$receipt_swap_env" <<'EOF'
set -T
swap_chaos_receipt_before_read_bind() {
    if [[ ( "${BASH_COMMAND:-}" == 'exec 13<'* \
            || "${BASH_COMMAND:-}" == 'exec 12<>'* ) \
            && -n "${PENDING_RECEIPT_PATH:-}" \
            && ! -e "${ODYSSEUS_TEST_RECEIPT_SWAP_DONE:?}" ]]; then
        trap - DEBUG
        if [[ -e "$PENDING_RECEIPT_PATH" \
                || -L "$PENDING_RECEIPT_PATH" ]]; then
            /bin/mv -- "$PENDING_RECEIPT_PATH" \
                "${ODYSSEUS_TEST_RECEIPT_SWAP_HELD:?}"
        else
            : > "${ODYSSEUS_TEST_RECEIPT_SWAP_HELD:?}"
        fi
        /usr/bin/mkfifo "$PENDING_RECEIPT_PATH"
        : > "$ODYSSEUS_TEST_RECEIPT_SWAP_DONE"
    fi
}
trap swap_chaos_receipt_before_read_bind DEBUG
EOF
receipt_swap_done="$fixture_root/chaos-receipt-swap.done"
receipt_swap_held="$fixture_root/chaos-receipt-swap.held"
receipt_swap_tmp=$(mktemp -d /tmp/odar.XXXXXX)
if run_chaos_case_bounded chaos-receipt-swap env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    TMPDIR="$receipt_swap_tmp" \
    BASH_ENV="$receipt_swap_env" \
    ODYSSEUS_TEST_RECEIPT_SWAP_DONE="$receipt_swap_done" \
    ODYSSEUS_TEST_RECEIPT_SWAP_HELD="$receipt_swap_held" \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-receipt-swap.state"; then
    fail "chaos accepted a swapped launcher receipt at its read-bind boundary"
elif [ ! -e "$receipt_swap_done" ]; then
    fail "chaos receipt race fixture did not reach the read-bind boundary"
elif [ -f "$receipt_swap_held" ] \
     && [ "$(wc -c < "$receipt_swap_held" | tr -d ' ')" -eq 0 ] \
     && ! grep -Fq 'exceeded its 15-second test bound' \
        "$fixture_root/chaos-receipt-swap.out"; then
    pass "chaos rejects a FIFO replacement without blocking or reopening the receipt pathname"
else
    fail "chaos receipt FIFO race did not preserve the exact created object"
fi

receipt_socket_env="$fixture_root/chaos-receipt-socket.bash"
cat > "$receipt_socket_env" <<'EOF'
set -T
swap_chaos_receipt_for_socket() {
    if [[ ( "${BASH_COMMAND:-}" == 'exec 13<'* \
            || "${BASH_COMMAND:-}" == 'exec 12<>'* ) \
            && -n "${PENDING_RECEIPT_PATH:-}" \
            && ! -e "${ODYSSEUS_TEST_RECEIPT_SOCKET_DONE:?}" ]]; then
        trap - DEBUG
        if [[ -e "$PENDING_RECEIPT_PATH" \
                || -L "$PENDING_RECEIPT_PATH" ]]; then
            /bin/mv -- "$PENDING_RECEIPT_PATH" \
                "${ODYSSEUS_TEST_RECEIPT_SOCKET_HELD:?}"
        else
            : > "${ODYSSEUS_TEST_RECEIPT_SOCKET_HELD:?}"
        fi
        "${ODYSSEUS_TEST_REAL_PYTHON:?}" -I -E -c '
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
' "$PENDING_RECEIPT_PATH"
        : > "$ODYSSEUS_TEST_RECEIPT_SOCKET_DONE"
    fi
}
trap swap_chaos_receipt_for_socket DEBUG
EOF
receipt_socket_done="$fixture_root/chaos-receipt-socket.done"
receipt_socket_held="$fixture_root/chaos-receipt-socket.held"
if run_chaos_case_bounded chaos-receipt-socket env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    TMPDIR="$receipt_swap_tmp" \
    BASH_ENV="$receipt_socket_env" \
    ODYSSEUS_TEST_RECEIPT_SOCKET_DONE="$receipt_socket_done" \
    ODYSSEUS_TEST_RECEIPT_SOCKET_HELD="$receipt_socket_held" \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-receipt-socket.state"; then
    fail "chaos accepted a socket replacement at its receipt boundary"
elif [ ! -e "$receipt_socket_done" ]; then
    fail "chaos receipt socket fixture did not reach the open boundary"
elif [ -f "$receipt_socket_held" ] \
     && [ "$(wc -c < "$receipt_socket_held" | tr -d ' ')" -eq 0 ] \
     && ! grep -Fq 'exceeded its 15-second test bound' \
        "$fixture_root/chaos-receipt-socket.out"; then
    pass "chaos rejects a socket replacement without blocking or reopening the receipt pathname"
else
    fail "chaos receipt socket race did not preserve the exact created object"
fi
rm -r -- "$receipt_swap_tmp"
receipt_swap_tmp=""

if run_chaos_case chaos-cidfile-retarget env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_RETARGET_CIDFILE=1 \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-cidfile-retarget.state"; then
    if ! grep -Fxq \
            'podman rm -f eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' \
            "$fixture_root/chaos-cidfile-retarget.effects" \
       && grep -Fxq \
            'podman rm -f aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
            "$fixture_root/chaos-cidfile-retarget.effects" \
       && grep -Fxq \
            'podman rm -f dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
            "$fixture_root/chaos-cidfile-retarget.effects"; then
        pass "C4-C6 ignore cidfile retargets and mutate only launcher-receipted IDs"
    else
        fail "chaos adopted an unrelated ID from a retargeted cidfile"
    fi
else
    fail "cidfile-retarget fixture did not complete with descriptor-bound receipts"
fi

if run_chaos_case chaos-c5-replaced env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_REPLACE_C5=1 \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-replaced.state"; then
    fail "live chaos accepted replacement of its bound C5 victim"
elif grep -Fq 'C5: bound victim identity is unavailable' \
       "$fixture_root/chaos-c5-replaced.out" \
     && ! grep -q '^podman kill ' \
       "$fixture_root/chaos-c5-replaced.effects"; then
    pass "live chaos never adopts a same-name same-metadata replacement"
else
    fail "live chaos killed or hid a replacement of its bound C5 victim"
fi

if run_chaos_case chaos-c4-seed-unavailable env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_C4_SEED_RC=125 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c4-seed.state"; then
    fail "enabled C4 accepted an unavailable fixture seed"
elif grep -Fq 'C4: fixture seed unavailable' \
     "$fixture_root/chaos-c4-seed-unavailable.out"; then
    pass "enabled C4 reports an unavailable fixture seed as failure"
else
    fail "enabled C4 hid its unavailable fixture seed"
fi

if run_chaos_case chaos-c4-state-unavailable env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=not-running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c4-state.state"; then
    fail "enabled C4 accepted a fixture that was not running"
elif grep -Fq 'C4: seeded fixture was not running' \
     "$fixture_root/chaos-c4-state-unavailable.out"; then
    pass "enabled C4 requires a verified running fixture"
else
    fail "enabled C4 hid its unavailable running state"
fi

if run_chaos_case chaos-container-state-unavailable env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CONTAINER_MODE=exists-fail; then
    fail "live chaos accepted an unavailable container existence state"
elif grep -Fq 'C4: container existence state is unavailable' \
       "$fixture_root/chaos-container-state-unavailable.out" \
     && ! grep -q '^podman run -d' \
       "$fixture_root/chaos-container-state-unavailable.effects"; then
    pass "live chaos does not seed from an unavailable existence state"
else
    fail "live chaos treated an unavailable existence state as absence"
fi

if run_chaos_case chaos-c5-launch-unavailable env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_C5_LAUNCH_RC=42 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-launch.state"; then
    fail "enabled C5 accepted an unavailable training launch"
elif grep -Fq 'C5: training launch unavailable' \
     "$fixture_root/chaos-c5-launch-unavailable.out"; then
    pass "enabled C5 reports an unavailable training launch as failure"
else
    fail "enabled C5 hid its unavailable training launch"
fi

if run_chaos_case chaos-c5-partial-result env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_C5_LAUNCH_RC=42 \
    ODYSSEUS_TEST_CHAOS_C5_CREATE_RESULTS_BEFORE_FAIL=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-partial.state"; then
    fail "C5 partial launch failure was reported as successful chaos completion"
else
    c5_partial_run=$(awk '/^train run=.*-c5$/ {
        sub(/^train run=/, ""); print; exit
    }' "$fixture_root/chaos-c5-partial-result.log")
    c5_partial_results="$fixture_root/home/alexnet-results/runs/$c5_partial_run/hub"
    if [[ "$c5_partial_run" =~ ^chaos-[A-Za-z0-9._-]+-c5$ ]] \
       && [ ! -e "$c5_partial_results" ] \
       && [ ! -L "$c5_partial_results" ] \
       && grep -Fq 'pending fixture created an exactly bound result tree' \
            "$fixture_root/chaos-c5-partial-result.out"; then
        pass "C5 removes an exactly bound partial result after launcher failure"
    else
        fail "C5 leaked or ambiguously removed a partial launcher result tree"
    fi
fi

if run_chaos_case chaos-c5-not-running env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=not-running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-not-running.state"; then
    fail "enabled C5 accepted a victim that was not running"
elif grep -Fq 'C5: victim was not running' \
       "$fixture_root/chaos-c5-not-running.out" \
     && ! grep -q '^podman kill alexnet-training' \
       "$fixture_root/chaos-c5-not-running.effects"; then
    pass "enabled C5 refuses to kill an unverified victim"
else
    fail "enabled C5 killed or hid an unverified victim"
fi

if run_chaos_case chaos-c5-kill-failed env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_KILL_RC=55 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=running \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-kill.state"; then
    fail "enabled C5 accepted a failed victim kill"
elif grep -Fq 'C5: victim kill failed' \
       "$fixture_root/chaos-c5-kill-failed.out" \
     && ! grep -Eq '^wait run=.*-c5 ' \
       "$fixture_root/chaos-c5-kill-failed.log"; then
    pass "enabled C5 stops when the victim kill fails"
else
    fail "enabled C5 continued after a failed victim kill"
fi

if run_chaos_case chaos-c5-zero-exit env \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_LIVE=1 \
    ODYSSEUS_TEST_CHAOS_VICTIM_MODE=zero-exit \
    ODYSSEUS_TEST_CHAOS_STATE_FILE="$fixture_root/chaos-c5-zero.state"; then
    fail "enabled C5 accepted zero exit evidence after a kill"
elif grep -Fq 'C5: killed victim did not report a non-zero exit' \
       "$fixture_root/chaos-c5-zero-exit.out" \
     && ! grep -Eq '^wait run=.*-c5 ' \
       "$fixture_root/chaos-c5-zero-exit.log"; then
    pass "enabled C5 requires non-zero victim exit evidence"
else
    fail "enabled C5 continued without non-zero victim exit evidence"
fi

: > "$fixture_root/chaos-network.calls"
: > "$fixture_root/chaos-network.effects"
: > "$fixture_root/chaos-network.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-network.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-network.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-network.log" \
    ODYSSEUS_TEST_TAILSCALE_JSON='{"Peer":{"peer":{"HostName":"hermes","Online":false}}}' \
    ODYSSEUS_TEST_CHAOS_TEARDOWN_RC=2 \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    ALEXNET_CHAOS_APPROVED_OFFLINE_HOST=hermes CHAOS_NETWORK=1 \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-network.out" 2>&1; then
    if grep -Fq 'C1: offline target was rejected by complete resolution' \
           "$fixture_root/chaos-network.out" \
       && grep -Fq 'C2: unresolved target was rejected by complete resolution' \
           "$fixture_root/chaos-network.out" \
       && grep -Fq \
           'alexnet-deploy-fleet.sh fleet=hub no-such-host-xyz approval= deploy_approval= dry=1' \
           "$fixture_root/chaos-network.log"; then
        pass "network chaos reaches C2 resolution in an unapproved dry-run"
    else
        fail "network chaos accepted non-specific failures"
    fi
else
    fail "approved mocked network chaos did not complete"
fi

: > "$fixture_root/chaos-inventory-fail.calls"
: > "$fixture_root/chaos-inventory-fail.effects"
: > "$fixture_root/chaos-inventory-fail.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-inventory-fail.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-inventory-fail.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-inventory-fail.log" \
    ODYSSEUS_TEST_TAILSCALE_RC=17 \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_NETWORK=1 \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-inventory-fail.out" 2>&1; then
    fail "network chaos skipped a failed current-inventory readback"
elif grep -Fq 'current Tailscale inventory readback failed' \
     "$fixture_root/chaos-inventory-fail.out"; then
    pass "network chaos reports an unavailable current inventory as failure"
else
    fail "network chaos hid the inventory readback failure"
fi

: > "$fixture_root/chaos-false-green.calls"
: > "$fixture_root/chaos-false-green.effects"
: > "$fixture_root/chaos-false-green.log"
if ODYSSEUS_TEST_CALL_LOG="$fixture_root/chaos-false-green.calls" \
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/chaos-false-green.effects" \
    ODYSSEUS_TEST_CHAOS_LOG="$fixture_root/chaos-false-green.log" \
    ODYSSEUS_TEST_CHAOS_DEPLOY_RC=0 \
    HOME="$fixture_root/home" PATH="$fixture_bin:/usr/bin:/bin" \
    ALEXNET_CHAOS_APPROVED_HOST=hub CHAOS_NETWORK=1 \
    bash "$chaos_root/e2e/alexnet-mesh-chaos.sh" \
    > "$fixture_root/chaos-false-green.out" 2>&1; then
    fail "chaos accepted success from a case that must fail closed"
elif grep -Fq 'unexpectedly succeeded' \
     "$fixture_root/chaos-false-green.out"; then
    pass "chaos failure cases reject an unexpected zero exit"
else
    fail "chaos did not expose the unexpected success"
fi

if run_chaos_case chaos-no-image env \
    ODYSSEUS_TEST_IMAGE_EXISTS=0 ALEXNET_CHAOS_APPROVED_HOST=hub; then
    fail "enabled C6 and C7 accepted an unavailable local fixture image"
elif grep -q '^podman run -d' "$fixture_root/chaos-no-image.effects"; then
    fail "hermetic chaos attempted a fallback image pull"
elif grep -Fq 'C6: exact local fixture image is unavailable' \
       "$fixture_root/chaos-no-image.out" \
     && grep -Fq 'C7: C6 did not create the teardown fixture' \
       "$fixture_root/chaos-no-image.out"; then
    pass "enabled C6 and C7 report an unavailable local fixture as failure"
else
    fail "enabled C6 or C7 hid the unavailable local fixture"
fi

c6_bound_image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if run_chaos_case chaos-c6-tag-retarget env \
    ALEXNET_CHAOS_APPROVED_HOST=hub ODYSSEUS_TEST_CHAOS_RETARGET_C6=1; then
    if grep -Fq " $c6_bound_image_id sh -c echo \"Training complete!\"" \
            "$fixture_root/chaos-c6-tag-retarget.effects" \
       && ! grep -Fq ' localhost/odyssey:dev sh -c echo "Training complete!"' \
            "$fixture_root/chaos-c6-tag-retarget.effects" \
       && grep -Fq 'C6: smoke gate accepted the exact marker-only run' \
            "$fixture_root/chaos-c6-tag-retarget.out"; then
        pass "C6 binds its launch to the inspected image ID when the tag retargets"
    else
        fail "C6 launched through a retargetable image tag"
    fi
else
    fail "C6 rejected the immutable image fixture after a tag retarget"
fi

if run_chaos_case chaos-c6-replaced env \
    ALEXNET_CHAOS_APPROVED_HOST=hub ODYSSEUS_TEST_CHAOS_REPLACE_C6=1; then
    fail "C6 accepted a same-name replacement of its fixture"
elif grep -Fq 'C6: seeded fixture identity is unavailable; replacement was preserved' \
        "$fixture_root/chaos-c6-replaced.out" \
     && ! grep -Eq '^wait run=.*-c6 ' "$fixture_root/chaos-c6-replaced.log" \
     && ! grep -Eq 'alexnet-fleet-teardown.sh .*run=.*-c6' \
        "$fixture_root/chaos-c6-replaced.log" \
     && ! grep -q '^podman rm -f ' "$fixture_root/chaos-c6-replaced.effects"; then
    pass "C6 rejects a same-name replacement before wait or teardown"
else
    fail "C6 did not preserve a same-name fixture replacement"
fi

if run_chaos_case chaos-c6-interrupted env \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    ODYSSEUS_TEST_CHAOS_INTERRUPT_C6=1; then
    fail "C6 interruption was reported as successful completion"
else
    interrupted_run=$(awk '/^wait run=.*-c6 / {
        sub(/^wait run=/, ""); sub(/ args=.*/, ""); print; exit
    }' "$fixture_root/chaos-c6-interrupted.log")
    interrupted_results="$fixture_root/home/.cache/odysseus-alexnet-chaos/runs/$interrupted_run/hub"
    if [[ "$interrupted_run" =~ ^chaos-[A-Za-z0-9._-]+-c6$ ]] \
       && grep -Fxq \
            'podman rm -f dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
            "$fixture_root/chaos-c6-interrupted.effects" \
       && [ ! -e "$interrupted_results" ] \
       && [ ! -L "$interrupted_results" ]; then
        pass "C6 interruption removes only the registered container and bound result tree"
    else
        fail "C6 interruption leaked its registered container or bound result tree"
    fi
fi

if run_chaos_case chaos-c6-spawn-interrupted env \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_SPAWN=1; then
    fail "C6 spawn-window interruption was reported as successful completion"
else
    spawn_interrupted_run=$(sed -n \
        's/.*io\.homeric\.alexnet\.run-id=\([^ ]*\).*/\1/p' \
        "$fixture_root/chaos-c6-spawn-interrupted.effects" | tail -1)
    spawn_interrupted_results="$fixture_root/home/.cache/odysseus-alexnet-chaos/runs/$spawn_interrupted_run/hub"
    if [[ "$spawn_interrupted_run" =~ ^chaos-[A-Za-z0-9._-]+-c6$ ]] \
       && ! grep -q '^podman rm -f ' \
            "$fixture_root/chaos-c6-spawn-interrupted.effects" \
       && [ -d "$spawn_interrupted_results" ] \
       && grep -Fq 'pending exact fixture is absent but a same-name replacement was preserved' \
            "$fixture_root/chaos-c6-spawn-interrupted.out"; then
        pass "C6 spawn interruption retains an unreceipted container and its bound results"
    else
        fail "C6 spawn interruption leaked or overreached its pending fixture"
    fi
fi

c6_prereadiness_hook="$fixture_root/chaos-c6-prereadiness-hook.sh"
cat > "$c6_prereadiness_hook" <<'EOF'
set -T
chaos_interrupt_before_worker_readiness() {
    if [[ "${ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_BEFORE_READY:-0}" == 1 \
            && "${PENDING_CONTAINER_RUN:-}" == *-c6 \
            && ( "${BASH_COMMAND:-}" == prepare_spawn_worker \
                || "${BASH_COMMAND:-}" == 'exec 14< '* ) ]]; then
        trap - DEBUG
        printf '%s\n' "$PENDING_CONTAINER_RUN" \
            > "${ODYSSEUS_TEST_CHAOS_PREREADINESS_RUN_FILE:?}"
        kill -TERM "${SPAWN_CONTROLLER_PID:?}"
        /bin/sleep 0.5
        : > "${ODYSSEUS_TEST_CHAOS_NATURAL_FINISH:?}"
        exit 143
    fi
}
trap chaos_interrupt_before_worker_readiness DEBUG
EOF
c6_prereadiness_natural="$fixture_root/chaos-c6-prereadiness.natural"
c6_prereadiness_run_file="$fixture_root/chaos-c6-prereadiness.run"
if run_chaos_case_bounded chaos-c6-prereadiness-signal env \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    BASH_ENV="$c6_prereadiness_hook" \
    ODYSSEUS_TEST_CHAOS_INTERRUPT_C6_BEFORE_READY=1 \
    ODYSSEUS_TEST_CHAOS_PREREADINESS_RUN_FILE="$c6_prereadiness_run_file" \
    ODYSSEUS_TEST_CHAOS_NATURAL_FINISH="$c6_prereadiness_natural"; then
    fail "C6 pre-readiness interruption was reported as successful completion"
else
    # The adversarial child intentionally finishes naturally on platforms
    # without stable process handles. Wait a fixed bound so either its marker
    # is observable or Linux has proved it was extinguished before readiness.
    /bin/sleep 1
    prereadiness_run=$(<"$c6_prereadiness_run_file")
    prereadiness_results="$fixture_root/home/.cache/odysseus-alexnet-chaos/runs/$prereadiness_run/hub"
    c6_prereadiness_lifecycle_ok=0
    c6_prereadiness_result_ok=0
    if [ "$darwin_worker_fail_closed" = 1 ]; then
        if [ -e "$c6_prereadiness_natural" ] \
                && [ -d "$prereadiness_results" ]; then
            c6_prereadiness_lifecycle_ok=1
            c6_prereadiness_result_ok=1
        fi
    elif [ ! -e "$c6_prereadiness_natural" ] \
            && [ ! -e "$prereadiness_results" ] \
            && [ ! -L "$prereadiness_results" ]; then
        c6_prereadiness_lifecycle_ok=1
        c6_prereadiness_result_ok=1
    fi
    c6_prereadiness_diagnostic_ok=0
    if [ "$darwin_worker_fail_closed" = 1 ]; then
        if grep -Fq 'fixture launcher extinction was not verified; owned resources were retained' \
                "$fixture_root/chaos-c6-prereadiness-signal.out"; then
            c6_prereadiness_diagnostic_ok=1
        fi
    elif grep -Fq 'pending fixture created an exactly bound result tree; cleanup will remove it' \
            "$fixture_root/chaos-c6-prereadiness-signal.out"; then
        c6_prereadiness_diagnostic_ok=1
    fi
    if [[ "$prereadiness_run" =~ ^chaos-[A-Za-z0-9._-]+-c6$ ]] \
       && [ "$c6_prereadiness_lifecycle_ok" -eq 1 ] \
       && [ "$c6_prereadiness_result_ok" -eq 1 ] \
       && [ "$c6_prereadiness_diagnostic_ok" -eq 1 ] \
       && ! grep -Eq '^podman (create|rm -f) ' \
            "$fixture_root/chaos-c6-prereadiness-signal.effects"; then
        if [ "$darwin_worker_fail_closed" = 1 ]; then
            pass "C6 bounds a pre-readiness signal and retains state when stable process handles are unavailable"
        else
            pass "C6 rolls back a signal received before child readiness without adopting a fixture"
        fi
    else
        fail "C6 waited for or leaked a launcher interrupted before child readiness"
    fi
fi

if run_chaos_case chaos-c6-replaced-after-rm env \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    ODYSSEUS_TEST_CHAOS_REPLACE_AFTER_RM=1; then
    fail "C6 cleanup accepted a same-name replacement created after exact-ID removal"
else
    replace_after_rm_run=$(sed -n \
        's/.*io\.homeric\.alexnet\.run-id=\([^ ]*\).*/\1/p' \
        "$fixture_root/chaos-c6-replaced-after-rm.effects" | head -1)
    replace_after_rm_results="$fixture_root/home/.cache/odysseus-alexnet-chaos/runs/$replace_after_rm_run/hub"
    if [[ "$replace_after_rm_run" =~ ^chaos-[A-Za-z0-9._-]+-c6$ ]] \
       && grep -Fq 'same-name replacement was preserved; bound results were retained' \
            "$fixture_root/chaos-c6-replaced-after-rm.out" \
       && [ -d "$replace_after_rm_results" ] \
       && [ "$(grep -Ec '^podman rm -f ' \
            "$fixture_root/chaos-c6-replaced-after-rm.effects")" -eq 1 ]; then
        pass "C6 re-probes the name and preserves a replacement created after exact-ID removal"
    else
        fail "C6 removed results or retried against a replacement created after exact-ID removal"
    fi
fi

if run_chaos_case chaos-c6-seed-failure env \
    ALEXNET_CHAOS_APPROVED_HOST=hub \
    ODYSSEUS_TEST_CHAOS_C6_SEED_RC=73; then
    fail "C6 seed failure was reported as successful completion"
else
    failed_seed_run=$(sed -n \
        's/.*io\.homeric\.alexnet\.run-id=\([^ ]*\).*/\1/p' \
        "$fixture_root/chaos-c6-seed-failure.effects" | tail -1)
    failed_seed_results="$fixture_root/home/.cache/odysseus-alexnet-chaos/runs/$failed_seed_run/hub"
    if [[ "$failed_seed_run" =~ ^chaos-[A-Za-z0-9._-]+-c6$ ]] \
       && [ ! -e "$failed_seed_results" ] \
       && [ ! -L "$failed_seed_results" ] \
       && ! grep -q '^podman rm -f ' \
            "$fixture_root/chaos-c6-seed-failure.effects"; then
        pass "C6 launch failure removes the bound result tree without inventing container ownership"
    else
        fail "C6 launch failure leaked results or removed an unowned container"
    fi
fi

info "destructive cleanup is exact-object quarantined"

if "$real_python" -I - "$ROOT/scripts/check_silent_failures.py" \
        "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        "$ROOT/e2e/alexnet-collect-results.sh" \
        "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        "$ROOT/e2e/alexnet-mesh-chaos.sh" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location(
    "alexnet_silent_failure_policy", sys.argv[1]
)
if spec is None or spec.loader is None:
    raise SystemExit("could not load the silent-failure policy")
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
findings = []
for value in sys.argv[2:]:
    path = Path(value)
    with path.open(encoding="utf-8") as stream:
        for line, message in policy._shell_findings(stream):
            findings.append(f"{path}:{line}: {message}")
if findings:
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)
PY
then
    pass "AlexNet operations contain no silent-failure suppressions"
else
    fail "AlexNet operations contain a forbidden silent-failure suppression"
fi

for cleanup_script in \
    e2e/alexnet-deploy-fleet.sh \
    e2e/alexnet-fleet-teardown.sh \
    e2e/alexnet-mesh-chaos.sh; do
    if grep -Eq 'os\.(unlink|rmdir)\(quarantine_name' "$ROOT/$cleanup_script"; then
        fail "$cleanup_script still name-deletes a replaceable quarantine entry"
    elif ! grep -Eq 'renameat2|renameatx_np' "$ROOT/$cleanup_script"; then
        fail "$cleanup_script does not use atomic no-replace quarantine publication"
    else
        pass "$cleanup_script preserves quarantined exact objects without a final name-delete race"
    fi
done

if grep -Eq 'os\.stat\(path, follow_symlinks=False\)|LSOF_BIN.*sentinel' \
        "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        "$ROOT/e2e/alexnet-collect-results.sh" \
        "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        "$ROOT/e2e/alexnet-mesh-chaos.sh"; then
    fail "worker containment still trusts a mutable sentinel pathname"
elif ! grep -Fq 'active_worker_sentinel_ids' \
        "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        "$ROOT/e2e/alexnet-collect-results.sh" \
        "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        || ! grep -Fq 'SPAWN_SENTINEL_ID' \
            "$ROOT/e2e/alexnet-mesh-chaos.sh" \
        || ! grep -Fq 'wait_worker_sentinel_ready' \
            "$ROOT/e2e/alexnet-deploy-fleet.sh" \
            "$ROOT/e2e/alexnet-collect-results.sh" \
            "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        || ! grep -Fq 'wait_spawn_worker_ready' \
            "$ROOT/e2e/alexnet-mesh-chaos.sh" \
        || grep -Fq "exec 19< \"\$worker_sentinel\"" \
            "$ROOT/e2e/alexnet-deploy-fleet.sh" \
            "$ROOT/e2e/alexnet-collect-results.sh" \
            "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        || grep -Fq "exec 14< \"\$SPAWN_SENTINEL\"" \
            "$ROOT/e2e/alexnet-mesh-chaos.sh"; then
    fail "fleet workers do not bind launch and extinction to exact sentinel identities"
else
    pass "fleet workers use kernel-bound containment or fail closed"
fi

if grep -Fq ": > \"\$local_container_receipt\"" \
        "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        || grep -Fq "container_id=\$(cat \"\$container_receipt\")" \
            "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        || grep -Fq "rm -f -- \"\$container_receipt\"" \
            "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        || grep -Fq "set -o noclobber; : > \"\$PENDING_RECEIPT_PATH\"" \
            "$ROOT/e2e/alexnet-mesh-chaos.sh" \
        || grep -Fq "exec 13< \"\$PENDING_RECEIPT_PATH\"" \
            "$ROOT/e2e/alexnet-mesh-chaos.sh"; then
    fail "container receipts still have create/reopen or close/reopen gaps"
else
    pass "container receipts stay descriptor-bound from atomic creation through validation"
fi

if "$real_python" -I - \
        "$ROOT/e2e/alexnet-deploy-fleet.sh" \
        "$ROOT/e2e/alexnet-collect-results.sh" \
        "$ROOT/e2e/alexnet-fleet-teardown.sh" <<'PY'
from pathlib import Path
import sys

for value in sys.argv[1:]:
    source = Path(value).read_text(encoding="utf-8")
    marker = "retire_worker_pid() {"
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"{value}: missing extinction-before-retirement helper")
    end = source.find("\n}\n", start)
    body = source[start:end]
    extinction = body.find("extinguish_worker_sentinel")
    retirement = body.find("forget_worker_pid")
    if extinction < 0 or retirement < 0 or extinction > retirement:
        raise SystemExit(f"{value}: worker registration retires before extinction")
    if source.count('forget_worker_pid "') != 2:
        raise SystemExit(f"{value}: unexpected worker-registration retirement path")
    readiness = source.find("if ! wait_worker_sentinel_ready")
    rollback_extinction = source.find("extinguish_worker_sentinel", readiness)
    rollback_retirement = source.find('forget_worker_pid "$worker_pid"', readiness)
    if (readiness < 0 or rollback_extinction < readiness
            or rollback_retirement < rollback_extinction):
        raise SystemExit(f"{value}: readiness rollback retires before extinction")

deploy = Path(sys.argv[1]).read_text(encoding="utf-8")
start = deploy.index("run_parallel_phase() {")
phase = deploy[start:deploy.index("\n}\n", start)]
binding = phase.find('sentinel_ids+=("$sentinel_id")')
launch = phase.find("worker_launch_critical=1")
if binding < 0 or launch < 0 or binding > launch:
    raise SystemExit("deploy: a later sentinel setup failure can strand an earlier worker")

for value, terminal in (
    (sys.argv[2], "transfer_failed=0"),
    (sys.argv[3], "fleet_failed=0"),
):
    source = Path(value).read_text(encoding="utf-8")
    start = source.index("pids=()", source.index("trap 'handle_worker_signal"))
    launch = source[start:source.index(terminal, start)]
    if launch.count("for ((host_index = 0;") < 2:
        raise SystemExit(f"{value}: workers launch before all sentinels are bound")
PY
then
    pass "fleet worker registrations remain active through exact extinction"
else
    fail "fleet workers can escape after early registration retirement or setup failure"
fi
cleanup_contract_failed=0
# shellcheck disable=SC2016
if ! grep -Fq 'quarantine_bound_tree' "$ROOT/e2e/alexnet-deploy-fleet.sh" \
   || grep -Fq 'rm -r -- "$scratch_dir"' "$ROOT/e2e/alexnet-deploy-fleet.sh"; then
    fail "deploy cleanup is not bound to an atomically quarantined object"
    cleanup_contract_failed=1
fi
if ! grep -Fq 'quarantine_bound_result_entry' "$ROOT/e2e/alexnet-mesh-chaos.sh" \
   || grep -Fq 'os.unlink(entry_name, dir_fd=directory_fd)' \
        "$ROOT/e2e/alexnet-mesh-chaos.sh" \
   || grep -Fq 'os.rmdir(entry_name, dir_fd=directory_fd)' \
        "$ROOT/e2e/alexnet-mesh-chaos.sh"; then
    fail "chaos result cleanup has a final-syscall pathname race"
    cleanup_contract_failed=1
fi
if [[ "$cleanup_contract_failed" == 0 ]]; then
    pass "deploy and chaos cleanup quarantine exact objects before deletion"
fi

deploy_cleanup_swap_env="$fixture_root/deploy-cleanup-swap.bash"
cat > "$deploy_cleanup_swap_env" <<'EOF'
set -T
swap_deploy_before_quarantine() {
    if [[ "${BASH_COMMAND:-}" == cleanup_scratch \
            && -n "${scratch_dir:-}" \
            && ! -e "${ODYSSEUS_TEST_CLEANUP_SWAP_DONE:?}" ]]; then
        trap - DEBUG
        /bin/mv -- "$scratch_dir" "${ODYSSEUS_TEST_CLEANUP_HELD:?}"
        /bin/mkdir -- "$scratch_dir"
        printf '%s\n' 'preserve deploy cleanup replacement' > "$scratch_dir/sentinel.txt"
        : > "$ODYSSEUS_TEST_CLEANUP_SWAP_DONE"
    fi
}
trap swap_deploy_before_quarantine DEBUG
EOF
if run_operation deploy-final-cleanup-swap e2e/alexnet-deploy-fleet.sh env \
    FLEET=hub LOCAL_AS_BUILD=1 DRY_RUN=1 SKIP_BUILD=1 \
    SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
    BASH_ENV="$deploy_cleanup_swap_env" \
    ODYSSEUS_TEST_CLEANUP_SWAP_DONE="$fixture_root/deploy-cleanup-swap.done" \
    ODYSSEUS_TEST_CLEANUP_HELD="$fixture_root/deploy-cleanup-swap.held"; then
    fail "deploy accepted a replacement at the final cleanup boundary"
elif grep -Fq 'could not safely remove the bound invocation directory' \
        "$fixture_root/deploy-final-cleanup-swap.out" \
     && grep -Fxq 'preserve deploy cleanup replacement' \
        "$fixture_root"/odysseus-alexnet-deploy.*/sentinel.txt; then
    pass "deploy preserves a replacement swapped at its final cleanup boundary"
else
    fail "deploy cleanup swap was not retained with an explicit diagnostic"
fi

info "chaos launcher receipts remain descriptor-bound"
if grep -Fq 'os.open(name, flags, dir_fd=directory_fd)' \
        "$ROOT/e2e/alexnet-mesh-chaos.sh" \
   || ! grep -Fq 'os.pread(receipt_fd' "$ROOT/e2e/alexnet-mesh-chaos.sh"; then
    fail "chaos reopens a mutable cid receipt name"
else
    pass "C4-C6 read only the retained launcher receipt object"
fi

info "fleet workers use descriptor-bound extinction sentinels"
containment_contract_failed=0
for worker_script in \
    e2e/alexnet-deploy-fleet.sh \
    e2e/alexnet-collect-results.sh \
    e2e/alexnet-fleet-teardown.sh \
    e2e/alexnet-mesh-chaos.sh; do
    # shellcheck disable=SC2016
    if ! grep -Fq 'extinguish_worker_sentinel' "$ROOT/$worker_script" \
       || grep -Fq 'kill -TERM -- "-$worker_pid"' "$ROOT/$worker_script" \
       || grep -Fq 'kill -"$signal_name" "$holder"' "$ROOT/$worker_script"; then
        fail "$worker_script lacks bound full-extinction handling"
        containment_contract_failed=1
    fi
done
if [[ "$containment_contract_failed" == 0 ]]; then
    pass "deploy, collect, and chaos bind worker extinction to inherited sentinels"
fi

summary
exit_code
