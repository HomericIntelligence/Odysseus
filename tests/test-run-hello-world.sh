#!/usr/bin/env bash
# Hermetic caller tests for the E2E hello-world validation script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

info "wait_for stops within its deadline after a server accepts and stalls"
if python3 - "$ROOT/e2e/lib/common.sh" <<'PY'
import os
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

common_path = sys.argv[1]
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
release = threading.Event()
accepted = threading.Event()
request_received = threading.Event()


def accept_and_stall():
    connection, _ = listener.accept()
    accepted.set()
    try:
        connection.settimeout(2)
        request = b""
        while b"\r\n\r\n" not in request and len(request) <= 8192:
            chunk = connection.recv(4096)
            if not chunk:
                break
            request += chunk
        if request.startswith(b"GET /health HTTP/") and b"\r\nHost: 127.0.0.1:" in request:
            request_received.set()
        release.wait(10)
    finally:
        connection.close()


threading.Thread(target=accept_and_stall, daemon=True).start()
port = listener.getsockname()[1]
command = (
    f"source {shlex.quote(common_path)}; "
    f"wait_for http://127.0.0.1:{port}/health stalled-service 1"
)
started = time.monotonic()
process = subprocess.Popen(
    ["/bin/bash", "-c", command],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
try:
    if not accepted.wait(timeout=2) or not request_received.wait(timeout=2):
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise SystemExit(1)
    status = process.wait(timeout=3)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit(1)
finally:
    release.set()
    listener.close()
elapsed = time.monotonic() - started
raise SystemExit(
    0
    if status == 1
    and accepted.is_set()
    and request_received.is_set()
    and elapsed < 2.5
    else 1
)
PY
then
    pass "an accepted stalled connection cannot exceed the one-second wait budget"
else
    fail "an accepted stalled connection escaped the wait budget"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
FAKE_BIN="$TMP/bin"
CURL_LOG="$TMP/curl.log"
PODMAN_LOG="$TMP/podman.log"
STACK_STARTED_MARKER="$TMP/stack-started"
HELLO_HEALTH_COUNT_FILE="$TMP/hello-health-count"
UNBOUND_LOG_MARKER="$TMP/unbound-log-read"
WEBHOOK_ATTACK_OUTSIDE="$TMP/webhook-attack-outside"
WEBHOOK_ATTACK_DISPLACED="$TMP/webhook-attack-displaced"
WEBHOOK_ATTACK_REPLACEMENT="$TMP/webhook-attack-replacement"
WEBHOOK_ATTACK_MARKER="$TMP/webhook-attack-triggered"
WEBHOOK_SITE_PACKAGES="$TMP/site-packages"
WEBHOOK_SYSCALL_REPLACEMENT="$TMP/webhook-syscall-replacement"
WEBHOOK_QUARANTINE_RECEIPT="$TMP/webhook-quarantine-receipt"
WEBHOOK_ANCESTOR_PARENT="$TMP/webhook-evidence-parent"
WEBHOOK_ANCESTOR_DISPLACED="$TMP/webhook-evidence-parent-displaced"
WEBHOOK_ANCESTOR_LEAF_FILE="$TMP/webhook-evidence-leaf"
mkdir -p "$FIXTURE/e2e/lib" "$FIXTURE/infrastructure/Hermes" \
    "$FIXTURE/infrastructure/Argus" "$FIXTURE/provisioning/Myrmidons" \
    "$FAKE_BIN" "$WEBHOOK_SITE_PACKAGES"
cp "$ROOT/e2e/run-hello-world.sh" "$FIXTURE/e2e/run-hello-world.sh"
cp "$ROOT/e2e/lib/common.sh" "$FIXTURE/e2e/lib/common.sh"
printf '%s\n' 'services: {}' > "$FIXTURE/docker-compose.e2e.yml"
printf '%s\n' 'global:' > "$FIXTURE/e2e/prometheus.yml"

cat > "$FIXTURE/e2e/capture-nats-event.py" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True)
parser.add_argument("--port", required=True)
parser.add_argument("--subject", required=True)
parser.add_argument("--event", required=True)
parser.add_argument("--team-id", required=True)
parser.add_argument("--task-id", required=True)
parser.add_argument("--evidence-dir-fd", required=True, type=int)
parser.add_argument("--ready-name")
parser.add_argument("--output-name")
parser.add_argument("--ready-fd", type=int)
parser.add_argument("--output-fd", type=int)
parser.add_argument("--timeout", required=True)
args = parser.parse_args()


def publish(name, descriptor, value):
    close_descriptor = False
    if descriptor is None:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=args.evidence_dir_fd,
        )
        close_descriptor = True
    try:
        if (
            os.environ.get("WEBHOOK_EVIDENCE_SCENARIO") == "partial-ready"
            and name == args.ready_name
        ):
            os.write(descriptor, value[:1])
            time.sleep(0.3)
            os.write(descriptor, value[1:])
        else:
            os.write(descriptor, value)
        os.fsync(descriptor)
    finally:
        if close_descriptor:
            os.close(descriptor)


publish(args.ready_name, args.ready_fd, b"ready\n")
scenario = os.environ.get("WEBHOOK_EVIDENCE_SCENARIO", "positive")
if scenario == "term-resistant":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path(os.environ["WEBHOOK_CAPTURE_PID_FILE"]).write_text(f"{os.getpid()}\n")
    time.sleep(5)
    raise SystemExit(1)
if scenario == "missing":
    time.sleep(0.05)
    raise SystemExit(1)
if scenario == "term-resistant-descendant":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    descendant = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    Path(os.environ["WEBHOOK_CAPTURE_PID_FILE"]).write_text(f"{os.getpid()}\n")
    Path(os.environ["WEBHOOK_DESCENDANT_PID_FILE"]).write_text(
        f"{descendant.pid}\n"
    )
    time.sleep(30)
    raise SystemExit(1)
if scenario == "ready-then-exit":
    Path(os.environ["WEBHOOK_CAPTURE_PID_FILE"]).write_text(f"{os.getpid()}\n")
    raise SystemExit(0)
valid_scenarios = {"positive", "partial-ready"}
request_id = "req-e2e-1" if scenario in valid_scenarios else "unrelated-request"
subject = (
    "hi.tasks.e2e-team.e2e-webhook-task.updated"
    if scenario in valid_scenarios
    else "hi.tasks.other.other.updated"
)
payload = {
    "schema_version": 1,
    "event": "task.updated",
    "data": {"team_id": "e2e-team", "task_id": "e2e-webhook-task"},
    "timestamp": "2026-01-01T00:00:00+00:00",
    "request_id": request_id,
}
publish(
    args.output_name,
    args.output_fd,
    json.dumps({"subject": subject, "payload": payload}).encode(),
)
if scenario == "replace-final-names":
    os.rename(
        args.ready_name,
        "ready.displaced",
        src_dir_fd=args.evidence_dir_fd,
        dst_dir_fd=args.evidence_dir_fd,
    )
    os.rename(
        args.output_name,
        "event.displaced",
        src_dir_fd=args.evidence_dir_fd,
        dst_dir_fd=args.evidence_dir_fd,
    )
    forged_payload = dict(payload)
    forged_payload["request_id"] = "req-e2e-1"
    forged_payload["data"] = {
        "team_id": "e2e-team",
        "task_id": "e2e-webhook-task",
    }
    publish(args.ready_name, None, b"ready\n")
    publish(
        args.output_name,
        None,
        json.dumps(
            {
                "subject": "hi.tasks.e2e-team.e2e-webhook-task.updated",
                "payload": forged_payload,
            }
        ).encode(),
    )
sys.exit(0)
PY

cat > "$WEBHOOK_SITE_PACKAGES/sitecustomize.py" <<'PY'
import os
from pathlib import Path
import secrets
import sys

attack = os.environ.get("WEBHOOK_FINAL_SYSCALL_ATTACK", "")
replacement = os.environ.get("WEBHOOK_SYSCALL_REPLACEMENT", "")
marker = os.environ.get("WEBHOOK_ATTACK_MARKER", "")

if attack == "quarantine-collision":
    secrets.token_hex = lambda _size: "c" * 24
    if len(sys.argv) > 1 and os.path.isabs(sys.argv[1]):
        evidence = Path(sys.argv[1])
        if evidence.name.startswith("odysseus-webhook-evidence."):
            target = evidence.parent / f".{evidence.name}.quarantine-{'c' * 24}"
            try:
                target.mkdir(mode=0o700)
            except FileExistsError:
                pass
            receipt = os.environ.get("WEBHOOK_QUARANTINE_RECEIPT", "")
            if receipt and not Path(receipt).exists():
                metadata = target.stat()
                Path(receipt).write_text(
                    f"{target}\n{metadata.st_dev}:{metadata.st_ino}\n"
                )

if attack == "unlink-swap":
    real_unlink = os.unlink

    def swap_then_unlink(path, *args, **kwargs):
        directory_fd = kwargs.get("dir_fd")
        if path == "ready" and directory_fd is not None and replacement:
            os.rename(
                path,
                "ready.original",
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            os.rename(replacement, path, dst_dir_fd=directory_fd)
            Path(marker).write_text("unlink-swap\n")
        return real_unlink(path, *args, **kwargs)

    os.unlink = swap_then_unlink

if attack == "rmdir-swap":
    real_rmdir = os.rmdir

    def swap_then_rmdir(path, *args, **kwargs):
        directory_fd = kwargs.get("dir_fd")
        if (
            directory_fd is not None
            and ".quarantine-" in os.fspath(path)
            and replacement
        ):
            saved = os.fspath(path) + ".original"
            os.rename(
                path,
                saved,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
            os.rename(replacement, path, dst_dir_fd=directory_fd)
            Path(marker).write_text("rmdir-swap\n")
        return real_rmdir(path, *args, **kwargs)

    os.rmdir = swap_then_rmdir
PY

cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
if [ "${WEBHOOK_EVIDENCE_ATTACK:-none}" != retarget-parent ] \
    || [[ "$*" != *odysseus-webhook-evidence.* ]]; then
    exec /usr/bin/mktemp "$@"
fi
path=$(/usr/bin/mktemp "$@") || exit
if ! mv -- "$path" "${WEBHOOK_ATTACK_DISPLACED:?}" \
    || ! ln -s -- "${WEBHOOK_ATTACK_OUTSIDE:?}" "$path"; then
    exit 1
fi
: > "${WEBHOOK_ATTACK_MARKER:?}"
printf '%s\n' "$path"
SH

cat > "$FAKE_BIN/podman" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PODMAN_LOG"
known_container() {
    case "$1" in
        odysseus-nats-1|odysseus-agamemnon-1|odysseus-nestor-1|\
        odysseus-hermes-1|odysseus-prometheus-1|odysseus-loki-1|\
        odysseus-grafana-1|odysseus-argus-exporter-1|\
        odysseus-hello-myrmidon-1) return 0 ;;
    esac
    return 1
}
if [ "${1:-}" = container ] && [ "${2:-}" = exists ]; then
    known_container "${3:-}" || exit 1
    if [ "${HELLO_STACK_OWNERSHIP:-owned}" = absent-then-owned ] \
        && [ ! -e "${STACK_STARTED_MARKER:?}" ]; then
        exit 1
    fi
    exit 0
fi
if [ "${1:-}" = ps ] && [ "${2:-}" = -a ]; then
    if [ "${HELLO_STACK_OWNERSHIP:-owned}" = absent-then-owned ] \
        && [ ! -e "${STACK_STARTED_MARKER:?}" ]; then
        exit 0
    fi
    for index in $(seq 1 9); do
        printf '%064x\n' "$index"
    done
    if [ "${HELLO_EXTRA_PROJECT_CONTAINER:-none}" = present ]; then
        printf '%064x\n' 238
    fi
    exit 0
fi
if [ "${1:-}" = inspect ] && [ "${2:-}" = --format ]; then
    if [ "${HELLO_STACK_OWNERSHIP:-owned}" = absent-then-owned ] \
        && [ ! -e "${STACK_STARTED_MARKER:?}" ]; then
        exit 1
    fi
    target="${4:-}"
    names=(
        odysseus-nats-1
        odysseus-agamemnon-1
        odysseus-nestor-1
        odysseus-hermes-1
        odysseus-prometheus-1
        odysseus-loki-1
        odysseus-grafana-1
        odysseus-argus-exporter-1
        odysseus-hello-myrmidon-1
    )
    services=(
        nats agamemnon nestor hermes prometheus loki grafana
        argus-exporter hello-myrmidon
    )
    for index in "${!names[@]}"; do
        printf -v container_id '%064x' "$((index + 1))"
        if [ "$target" = "${names[$index]}" ] \
            || [ "$target" = "$container_id" ]; then
            project=odysseus
            if [ "${HELLO_STACK_OWNERSHIP:-owned}" = foreign ] \
                && [ "$index" -eq 0 ]; then
                project=foreign
            fi
            printf '%s|%s|%s|%s||\n' \
                "$container_id" "${names[$index]}" "$project" \
                "${services[$index]}"
            exit 0
        fi
    done
    exit 1
fi
if [ "${1:-}" = network ] && [ "${2:-}" = exists ]; then
    [ "${3:-}" = odysseus_homeric-mesh ] \
        || [ "${3:-}" = "$(printf '%064x' 255)" ] \
        || exit 1
    case "${HELLO_NETWORK_OWNERSHIP:-owned}" in
        absent) exit 1 ;;
        absent-then-owned)
            [ -e "${STACK_STARTED_MARKER:?}" ] || exit 1
            ;;
    esac
    exit 0
fi
if [ "${1:-}" = network ] && [ "${2:-}" = inspect ] \
    && [ "${3:-}" = --format ]; then
    target="${5:-}"
    [ "$target" = odysseus_homeric-mesh ] \
        || [ "$target" = "$(printf '%064x' 255)" ] \
        || exit 1
    project=odysseus
    if [ "${HELLO_NETWORK_OWNERSHIP:-owned}" = foreign ]; then
        project=foreign
    fi
    printf '%064x|odysseus_homeric-mesh|%s|homeric-mesh||\n' \
        255 "$project"
    exit 0
fi
if [ "${1:-}" = logs ]; then
    log_target="${!#}"
    if [ "${HELLO_LATE_UNBOUND_CONTAINER:-none}" = present ] \
        && [ "$log_target" = "$(printf '%064x' 238)" ]; then
        : > "${UNBOUND_LOG_MARKER:?}"
    fi
    exit 0
fi
if [ "${1:-}" = compose ]; then
    for argument in "$@"; do
        if [ "$argument" = up ]; then
            : > "${STACK_STARTED_MARKER:?}"
        elif [ "$argument" = logs ] \
            && [ "${HELLO_LATE_UNBOUND_CONTAINER:-none}" = present ]; then
            : > "${UNBOUND_LOG_MARKER:?}"
        fi
    done
    exit 0
fi
exit 97
SH

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
url=""
method=GET
previous=""
connect_timeout=""
max_time=""
write_out=""
output_target=""
for argument in "$@"; do
    case "$previous" in
        -X) method="$argument" ;;
        --connect-timeout) connect_timeout="$argument" ;;
        --max-time) max_time="$argument" ;;
        --write-out|-w) write_out="$argument" ;;
        --output|-o) output_target="$argument" ;;
    esac
    case "$argument" in http://*) url="$argument" ;; esac
    previous="$argument"
done

if [ -n "$url" ]; then
    case "$connect_timeout:$max_time" in
        *[!0-9:]*|0:*|*:0|:*) exit 98 ;;
    esac
    [ "$connect_timeout" -le "$max_time" ] || exit 98
    [ "$max_time" -le 15 ] || exit 98
fi

emit_response() {
    local body="$1" code="$2"
    if [ "$output_target" != /dev/null ] && [ -n "$body" ]; then
        printf '%s\n' "$body"
    fi
    if [ -n "$write_out" ]; then
        case "$write_out" in
            '%{http_code}') printf '%s' "$code" ;;
            *) printf '\n%s' "$code" ;;
        esac
    fi
}

case "${HELLO_EXHAUSTION_SCENARIO:-none}:$method:$url" in
    service:GET:http://localhost:8081/v1/health)
        exit 28
        ;;
    grafana:GET:http://localhost:3001/api/health)
        exit 28
        ;;
    task:GET:http://localhost:8080/v1/tasks)
        printf '%s\n' '{"tasks":[{"id":"task-1","status":"pending"}]}'
        exit 0
        ;;
esac

case "$method:$url" in
    GET:http://localhost:8080/v1/health|GET:http://localhost:8081/v1/health|GET:http://localhost:8085/health)
        if [ "$url" = http://localhost:8080/v1/health ]; then
            case "${HELLO_HTTP_SCENARIO:-valid}" in
                agamemnon-204) emit_response '' 204 ;;
                agamemnon-redirect) emit_response '' 302 ;;
                agamemnon-wrong-body) emit_response '{"status":"wrong"}' 200 ;;
                initial-unhealthy)
                    health_count=0
                    if [ -f "${HELLO_HEALTH_COUNT_FILE:?}" ]; then
                        health_count=$(cat "$HELLO_HEALTH_COUNT_FILE")
                    fi
                    health_count=$((health_count + 1))
                    printf '%s\n' "$health_count" > "$HELLO_HEALTH_COUNT_FILE"
                    if [ "$health_count" -eq 1 ]; then
                        emit_response '{"status":"wrong"}' 200
                    else
                        emit_response '{"status":"ok"}' 200
                    fi
                    ;;
                *) emit_response '{"status":"ok"}' 200 ;;
            esac
        else
            emit_response '{"status":"ok"}' 200
        fi
        ;;
    GET:http://localhost:8222/healthz)
        case "${HELLO_HTTP_SCENARIO:-valid}" in
            nats-204) emit_response '' 204 ;;
            nats-redirect) emit_response '' 302 ;;
            nats-wrong-body) emit_response 'not-ok' 200 ;;
            *) emit_response '{"status":"ok"}' 200 ;;
        esac
        ;;
    POST:http://localhost:8085/webhook)
        case "${HELLO_HTTP_SCENARIO:-valid}" in
            webhook-rejected) printf '%s\n' '{"status":"rejected"}' ;;
            webhook-transport-failure) exit 23 ;;
            *)
                printf '%s\n' \
                    '{"status":"accepted","event":"task.updated","request_id":"req-e2e-1"}'
                ;;
        esac
        ;;
    GET:http://localhost:8085/subjects)
        if [ "${WEBHOOK_EVIDENCE_ATTACK:-none}" = cleanup-replacement ]; then
            evidence_dir=$(find "${TMPDIR:?}" -maxdepth 1 -type d \
                -name 'odysseus-webhook-evidence.*' -print -quit)
            if [ -z "$evidence_dir" ] \
                || ! mv -- "$evidence_dir" "${WEBHOOK_ATTACK_DISPLACED:?}" \
                || ! mv -- "${WEBHOOK_ATTACK_REPLACEMENT:?}" "$evidence_dir"; then
                exit 92
            fi
            : > "${WEBHOOK_ATTACK_MARKER:?}"
        fi
        if [ "${WEBHOOK_EVIDENCE_ATTACK:-none}" = cleanup-ancestor ]; then
            python3 - "${TMPDIR:?}" "${WEBHOOK_ANCESTOR_DISPLACED:?}" \
                "${WEBHOOK_ANCESTOR_LEAF_FILE:?}" \
                "${WEBHOOK_ATTACK_MARKER:?}" <<'PY'
import os
import stat
import sys

parent, displaced, leaf_file, marker = sys.argv[1:]
root, parent_leaf = os.path.split(parent)
displaced_root, displaced_leaf = os.path.split(displaced)
if (
    not os.path.isabs(parent)
    or root != displaced_root
    or parent_leaf != "webhook-evidence-parent"
    or displaced_leaf != "webhook-evidence-parent-displaced"
):
    raise SystemExit(1)
root_metadata = os.stat(root, follow_symlinks=False)
if (
    not stat.S_ISDIR(root_metadata.st_mode)
    or root_metadata.st_uid != os.getuid()
    or stat.S_IMODE(root_metadata.st_mode) & 0o077
):
    raise SystemExit(1)
parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    leaves = [
        name
        for name in os.listdir(parent_fd)
        if name.startswith("odysseus-webhook-evidence.")
    ]
finally:
    os.close(parent_fd)
if len(leaves) != 1:
    raise SystemExit(1)
root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.rename(
        parent_leaf,
        displaced_leaf,
        src_dir_fd=root_fd,
        dst_dir_fd=root_fd,
    )
    os.mkdir(parent_leaf, 0o700, dir_fd=root_fd)
    replacement_parent_fd = os.open(
        parent_leaf, os.O_RDONLY | os.O_DIRECTORY, dir_fd=root_fd
    )
    try:
        os.mkdir(leaves[0], 0o700, dir_fd=replacement_parent_fd)
        replacement_fd = os.open(
            f"{leaves[0]}/cleanup-victim",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=replacement_parent_fd,
        )
        try:
            os.write(replacement_fd, b"preserve-ancestor-replacement\n")
        finally:
            os.close(replacement_fd)
    finally:
        os.close(replacement_parent_fd)
finally:
    os.close(root_fd)
with open(leaf_file, "w", encoding="utf-8") as stream:
    stream.write(f"{leaves[0]}\n")
with open(marker, "w", encoding="utf-8") as stream:
    stream.write("cleanup-ancestor\n")
PY
        fi
        case "${SUBJECTS_SCENARIO:-exact}" in
            exact)
                printf '%s\n' \
                    '{"subjects":["hi.tasks.e2e-team.e2e-webhook-task.updated"]}'
                ;;
            unrelated) printf '%s\n' '{"subjects":["hi.tasks.other.other.updated"]}' ;;
            historical) printf '%s\n' '{"subjects":["hi.tasks.old.old.updated"]}' ;;
            *) exit 93 ;;
        esac
        ;;
    POST:http://localhost:8080/v1/agents)
        printf '{"id":"%s"}\n' "${AGENT_ID_VALUE:-agent-1}"
        ;;
    POST:http://localhost:8080/v1/agents/agent-1/start)
        printf '%s\n' '{"status":"online"}'
        ;;
    GET:http://localhost:8080/v1/agents)
        printf '%s\n' '{"agents":[{"id":"agent-1","status":"online"}]}'
        ;;
    POST:http://localhost:8080/v1/teams)
        printf '{"team":{"id":"%s"}}\n' "${TEAM_ID_VALUE:-team-1}"
        ;;
    POST:http://localhost:8080/v1/teams/team-1/tasks)
        printf '{"task":{"id":"%s"}}\n' "${TASK_ID_VALUE:-task-1}"
        ;;
    GET:http://localhost:8080/v1/tasks)
        printf '%s\n' '{"tasks":[{"id":"task-1","status":"completed"}]}'
        ;;
    GET:http://localhost:9100/metrics)
        case "${METRICS_SCENARIO:-positive}" in
            positive)
                printf '%s\n' \
                    'hi_agamemnon_health{} 1' \
                    'hi_agents_total 1' \
                    'hi_agents_online 1' \
                    'hi_nestor_health{} 1' \
                    'hi_tasks_total 1' \
                    'hi_tasks_by_status{status="completed"} 1'
                ;;
            not-one)
                printf '%s\n' \
                    'hi_agamemnon_health 10' \
                    'hi_agents_total 1' \
                    'hi_agents_online 1' \
                    'hi_nestor_health 10' \
                    'hi_tasks_total 1' \
                    'hi_tasks_by_status{status="completed"} 1'
                ;;
            zero)
                printf '%s\n' \
                    'hi_agamemnon_health 1' \
                    'hi_agents_total 0' \
                    'hi_agents_online 0' \
                    'hi_nestor_health 1' \
                    'hi_tasks_total 0' \
                    'hi_tasks_by_status{status="completed"} 0'
                ;;
            comment-only)
                printf '%s\n' \
                    '# HELP hi_agamemnon_health 1' \
                    '# HELP hi_agents_total 1' \
                    '# HELP hi_agents_online 1' \
                    '# HELP hi_nestor_health 1' \
                    '# HELP hi_tasks_total 1' \
                    '# HELP hi_tasks_by_status{status="completed"} 1'
                ;;
            malformed)
                printf '%s\n' \
                    'invalid hi_agamemnon_health 1 trailing' \
                    'hi_agents_total not-a-number' \
                    'hi_agents_online not-a-number' \
                    'invalid hi_nestor_health 1 trailing' \
                    'hi_tasks_total not-a-number' \
                    'hi_tasks_by_status{status="completed"} not-a-number'
                ;;
            collision)
                printf '%s\n' \
                    'xhi_agamemnon_health 1' \
                    'hi_agents_total_suffix 1' \
                    'xhi_agents_online 1' \
                    'xhi_nestor_health 1' \
                    'hi_tasks_total_suffix 1' \
                    'xhi_tasks_by_status{status="completed"} 1'
                ;;
            nonfinite)
                printf '%s\n' \
                    '# HELP hi_agamemnon_health 1' \
                    'hi_agamemnon_health NaN' \
                    'hi_agents_total +Inf' \
                    'hi_agents_online +Inf' \
                    '# HELP hi_nestor_health 1' \
                    'hi_nestor_health -Inf' \
                    'hi_tasks_total +Inf' \
                    'hi_tasks_by_status{status="completed"} NaN'
                ;;
            *) exit 94 ;;
        esac
        ;;
    GET:http://localhost:8222/varz)
        case "${VARZ_SCENARIO:-positive}" in
            positive)
                count=0
                if [ -f "${VARZ_COUNT_FILE:?}" ]; then
                    count=$(cat "$VARZ_COUNT_FILE")
                fi
                count=$((count + 1))
                printf '%s\n' "$count" > "$VARZ_COUNT_FILE"
                if [ "$count" -eq 1 ]; then
                    printf '%s\n' '{"connections":4,"in_msgs":2}'
                else
                    printf '%s\n' '{"connections":4,"in_msgs":3}'
                fi
                ;;
            unchanged) printf '%s\n' '{"connections":4,"in_msgs":3}' ;;
            missing) printf '%s\n' '{"connections":4}' ;;
            zero) printf '%s\n' '{"connections":4,"in_msgs":0}' ;;
            malformed) printf '%s\n' '{"connections":4,"in_msgs":"3"}' ;;
            *) exit 96 ;;
        esac
        ;;
    GET:http://localhost:3001/api/health)
        emit_response '{"database":"ok"}' 200
        ;;
    *)
        printf 'unexpected curl boundary: %s %s\n' "$method" "$url" >&2
        exit 95
        ;;
esac
SH

chmod +x "$FAKE_BIN"/*

KILL_SHIM="$TMP/kill-shim.bash"
cat > "$KILL_SHIM" <<'SH'
kill() {
    reused_pid=""
    if [ "${WEBHOOK_REUSED_PID:-0}" = 1 ] \
        && [ -s "${WEBHOOK_CAPTURE_PID_FILE:-}" ]; then
        reused_pid=$(cat "$WEBHOOK_CAPTURE_PID_FILE")
    fi
    if [ "${1:-}" != -0 ]; then
        printf '%s\n' "$*" >> "${WEBHOOK_SIGNAL_LOG:?}"
    fi
    if [ -n "$reused_pid" ] && [ "${2:-}" = "$reused_pid" ]; then
        if [ "${1:-}" != -0 ]; then
            printf 'REUSED %s\n' "$*" >> "${WEBHOOK_SIGNAL_LOG:?}"
        fi
        return 0
    fi
    if [ "${WEBHOOK_KILL_FAILURE:-0}" = 1 ] && [ "${1:-}" = -KILL ]; then
        return 1
    fi
    builtin kill "$@"
}
SH

run_hello_world() {
    printf '%s\n' 'operator-owned-env' > "$FIXTURE/.env"
    : > "$CURL_LOG"
    : > "$PODMAN_LOG"
    VARZ_COUNT_FILE="$TMP/varz-count"
    rm -f "$VARZ_COUNT_FILE" "$STACK_STARTED_MARKER" \
        "$HELLO_HEALTH_COUNT_FILE" "$UNBOUND_LOG_MARKER" \
        "$TMP/webhook-capture.pid" "$TMP/webhook-signals.log" \
        "$TMP/webhook-descendant.pid" \
        "$WEBHOOK_ATTACK_MARKER" "$WEBHOOK_QUARANTINE_RECEIPT" \
        "$WEBHOOK_ANCESTOR_LEAF_FILE"
    set +e
    HELLO_OUTPUT="$(
        CURL_LOG="$CURL_LOG" \
        PODMAN_LOG="$PODMAN_LOG" \
        VARZ_COUNT_FILE="$VARZ_COUNT_FILE" \
        STACK_STARTED_MARKER="$STACK_STARTED_MARKER" \
        HELLO_HEALTH_COUNT_FILE="$HELLO_HEALTH_COUNT_FILE" \
        UNBOUND_LOG_MARKER="$UNBOUND_LOG_MARKER" \
        METRICS_SCENARIO="${METRICS_SCENARIO:-positive}" \
        VARZ_SCENARIO="${VARZ_SCENARIO:-positive}" \
        SUBJECTS_SCENARIO="${SUBJECTS_SCENARIO:-exact}" \
        WEBHOOK_EVIDENCE_SCENARIO="${WEBHOOK_EVIDENCE_SCENARIO:-positive}" \
        HELLO_HTTP_SCENARIO="${HELLO_HTTP_SCENARIO:-valid}" \
        HELLO_EXHAUSTION_SCENARIO="${HELLO_EXHAUSTION_SCENARIO:-none}" \
        HELLO_STACK_OWNERSHIP="${HELLO_STACK_OWNERSHIP:-owned}" \
        HELLO_EXTRA_PROJECT_CONTAINER="${HELLO_EXTRA_PROJECT_CONTAINER:-none}" \
        HELLO_NETWORK_OWNERSHIP="${HELLO_NETWORK_OWNERSHIP:-owned}" \
        HELLO_LATE_UNBOUND_CONTAINER="${HELLO_LATE_UNBOUND_CONTAINER:-none}" \
        WEBHOOK_CAPTURE_PID_FILE="$TMP/webhook-capture.pid" \
        WEBHOOK_DESCENDANT_PID_FILE="$TMP/webhook-descendant.pid" \
        WEBHOOK_SIGNAL_LOG="$TMP/webhook-signals.log" \
        WEBHOOK_EVIDENCE_ATTACK="${WEBHOOK_EVIDENCE_ATTACK:-none}" \
        WEBHOOK_ATTACK_OUTSIDE="$WEBHOOK_ATTACK_OUTSIDE" \
        WEBHOOK_ATTACK_DISPLACED="$WEBHOOK_ATTACK_DISPLACED" \
        WEBHOOK_ATTACK_REPLACEMENT="$WEBHOOK_ATTACK_REPLACEMENT" \
        WEBHOOK_ATTACK_MARKER="$WEBHOOK_ATTACK_MARKER" \
        WEBHOOK_KILL_FAILURE="${WEBHOOK_KILL_FAILURE:-0}" \
        WEBHOOK_REUSED_PID="${WEBHOOK_REUSED_PID:-0}" \
        WEBHOOK_FINAL_SYSCALL_ATTACK="${WEBHOOK_FINAL_SYSCALL_ATTACK:-}" \
        WEBHOOK_SYSCALL_REPLACEMENT="$WEBHOOK_SYSCALL_REPLACEMENT" \
        WEBHOOK_QUARANTINE_RECEIPT="$WEBHOOK_QUARANTINE_RECEIPT" \
        WEBHOOK_ANCESTOR_DISPLACED="$WEBHOOK_ANCESTOR_DISPLACED" \
        WEBHOOK_ANCESTOR_LEAF_FILE="$WEBHOOK_ANCESTOR_LEAF_FILE" \
        PYTHONPATH="${HELLO_PYTHONPATH:-}" \
        BASH_ENV="${HELLO_BASH_ENV:-}" \
        TMPDIR="${WEBHOOK_TMPDIR:-$TMP}" \
        COMPOSE_FILE="${COMPOSE_FILE:-}" \
        COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}" \
        AGENT_ID_VALUE="${AGENT_ID_VALUE:-agent-1}" \
        TEAM_ID_VALUE="${TEAM_ID_VALUE:-team-1}" \
        TASK_ID_VALUE="${TASK_ID_VALUE:-task-1}" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
            /bin/bash "$FIXTURE/e2e/run-hello-world.sh" 2>&1
    )"
    HELLO_STATUS=$?
    set -e
}

webhook_signal_order_is_bounded() {
    local capture_pid="$1"
    awk -v expected_pid="$capture_pid" '
        $1 == "-TERM" && $2 == expected_pid && term == 0 { term = NR }
        $1 == "-KILL" && $2 == expected_pid && kill == 0 { kill = NR }
        END { exit !(term > 0 && kill > term) }
    ' "$TMP/webhook-signals.log"
}

request_exhaustion_matches() {
    local expected_url="$1" expected_count="$2" expected_budget="$3"
    awk -v expected_url="$expected_url" \
        -v expected_count="$expected_count" \
        -v expected_budget="$expected_budget" '
function positive(value) { return value ~ /^[1-9][0-9]*$/ }
{
    url = ""
    connect = ""
    total = ""
    for (field = 1; field <= NF; field++) {
        if ($field ~ /^https?:\/\//) url = $field
        if ($field == "--connect-timeout") connect = $(field + 1)
        if ($field == "--max-time") total = $(field + 1)
    }
    if (url == expected_url) {
        seen++
        if (!positive(connect) || connect > expected_budget \
                || total != expected_budget) bad = 1
    }
}
END { exit !(seen == expected_count && bad == 0) }
' "$CURL_LOG"
}

info "foreign reserved-name containers stop before the first POST"
HELLO_STACK_OWNERSHIP=foreign run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Eqi 'foreign|ownership' <<<"$HELLO_OUTPUT" \
    && ! grep -Eq '(^| )-X POST( |$)' "$CURL_LOG" \
    && ! grep -Eq '(^| )logs( |$)' "$PODMAN_LOG"; then
    pass "health alone cannot authorize requests against a foreign stack"
else
    fail "a foreign same-name stack reached a mutating HTTP boundary"
fi

info "foreign reserved-name containers stop before compose startup"
HELLO_STACK_OWNERSHIP=foreign \
    HELLO_HTTP_SCENARIO=agamemnon-wrong-body run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Eqi 'foreign|ownership' <<<"$HELLO_OUTPUT" \
    && ! grep -Eq '(^| )up( |$)' "$PODMAN_LOG" \
    && ! grep -Eq '(^| )logs( |$)' "$PODMAN_LOG" \
    && ! grep -Eq '(^| )-X POST( |$)' "$CURL_LOG"; then
    pass "an unhealthy foreign stack cannot reach a Compose mutation"
else
    fail "compose startup mutated an unhealthy foreign reserved-name stack"
fi

info "unbound same-project containers stop before compose startup"
HELLO_EXTRA_PROJECT_CONTAINER=present \
    HELLO_HTTP_SCENARIO=agamemnon-wrong-body run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Eqi 'unbound|inventory|ownership' <<<"$HELLO_OUTPUT" \
    && ! grep -Eq '(^| )up( |$)' "$PODMAN_LOG" \
    && ! grep -Eq '(^| )logs( |$)' "$PODMAN_LOG"; then
    pass "Compose cannot adopt a different-name project container"
else
    fail "compose startup reached an unbound same-project container"
fi

info "a foreign reserved network stops before compose startup"
HELLO_NETWORK_OWNERSHIP=foreign \
    HELLO_HTTP_SCENARIO=agamemnon-wrong-body run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Eqi 'network|foreign|ownership' <<<"$HELLO_OUTPUT" \
    && ! grep -Eq '(^| )up( |$)' "$PODMAN_LOG" \
    && ! grep -Eq '(^| )logs( |$)' "$PODMAN_LOG"; then
    pass "Compose cannot reuse a foreign reserved-name network"
else
    fail "compose startup reached a foreign reserved-name network"
fi

info "an absent stack remains eligible for canonical startup"
HELLO_STACK_OWNERSHIP=absent-then-owned \
    HELLO_NETWORK_OWNERSHIP=absent-then-owned \
    HELLO_HTTP_SCENARIO=initial-unhealthy run_hello_world
if [ "$HELLO_STATUS" -eq 0 ] \
    && grep -Eq '(^| )up( |$)' "$PODMAN_LOG" \
    && grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
    pass "clean absence can transition to a verified owned stack"
else
    fail "ownership preflight blocked clean stack startup"
fi

info "post-receipt diagnostics log only exact immutable container IDs"
HELLO_LATE_UNBOUND_CONTAINER=present \
    HELLO_HTTP_SCENARIO=nats-wrong-body run_hello_world
owned_log_count=0
if ! owned_log_count=$(grep -Ec '^logs --tail 50 [0-9a-f]{64}$' \
    "$PODMAN_LOG"); then :; fi
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ ! -e "$UNBOUND_LOG_MARKER" ] \
    && ! grep -Eq '^compose .* logs( |$)' "$PODMAN_LOG" \
    && [ "$owned_log_count" -eq 9 ]; then
    pass "diagnostics cannot select a later unbound project container"
else
    fail "diagnostics read beyond the immutable owned container set"
fi

info "webhook EXIT cleanup escalates TERM to KILL and reaps the capture child"
HELLO_BASH_ENV="$KILL_SHIM" \
    WEBHOOK_EVIDENCE_SCENARIO=term-resistant \
    HELLO_HTTP_SCENARIO=webhook-rejected run_hello_world
webhook_capture_pid=""
if ! webhook_capture_pid=$(cat "$TMP/webhook-capture.pid" 2>/dev/null); then :; fi
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ -n "$webhook_capture_pid" ] \
    && webhook_signal_order_is_bounded "$webhook_capture_pid" \
    && ! /bin/kill -0 "$webhook_capture_pid" 2>/dev/null \
    && ! find "$TMP" -maxdepth 1 -type d \
        -name 'odysseus-webhook-evidence.*' -print -quit | grep -q .; then
    pass "a TERM-resistant capture child is killed and reaped before evidence removal"
else
    if [ -n "$webhook_capture_pid" ]; then
        if ! /bin/kill -KILL "$webhook_capture_pid" 2>/dev/null; then :; fi
    fi
    fail "webhook cleanup did not prove capture-child extinction"
fi

info "webhook cleanup failure retains evidence and preserves the earlier exit"
HELLO_BASH_ENV="$KILL_SHIM" \
    WEBHOOK_KILL_FAILURE=1 \
    WEBHOOK_EVIDENCE_SCENARIO=term-resistant \
    HELLO_HTTP_SCENARIO=webhook-transport-failure run_hello_world
webhook_capture_pid=""
if ! webhook_capture_pid=$(cat "$TMP/webhook-capture.pid" 2>/dev/null); then :; fi
webhook_evidence_dir=$(find "$TMP" -maxdepth 1 -type d \
    -name 'odysseus-webhook-evidence.*' -print -quit)
if [ "$HELLO_STATUS" -eq 23 ] \
    && [ -n "$webhook_capture_pid" ] \
    && grep -Fq -- "-KILL $webhook_capture_pid" "$TMP/webhook-signals.log" \
    && [ -n "$webhook_evidence_dir" ] \
    && grep -Eqi 'cleanup|capture.*still|extinction' <<<"$HELLO_OUTPUT"; then
    pass "failed capture extinction preserves evidence and the earlier status"
else
    fail "capture cleanup changed the earlier status or deleted its evidence"
fi
if [ -n "$webhook_capture_pid" ]; then
    if ! /bin/kill -KILL "$webhook_capture_pid" 2>/dev/null; then :; fi
fi
[ -z "$webhook_evidence_dir" ] \
    || rm -rf -- "$webhook_evidence_dir"

info "webhook evidence rejects a directory retarget before the first write"
rm -rf -- "$WEBHOOK_ATTACK_OUTSIDE" "$WEBHOOK_ATTACK_DISPLACED" \
    "$WEBHOOK_ATTACK_REPLACEMENT"
mkdir -p "$WEBHOOK_ATTACK_OUTSIDE"
printf '%s\n' 'outside-capture-error-sentinel' \
    > "$WEBHOOK_ATTACK_OUTSIDE/capture.err"
WEBHOOK_EVIDENCE_ATTACK=retarget-parent run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ -e "$WEBHOOK_ATTACK_MARKER" ] \
    && [ -d "$WEBHOOK_ATTACK_DISPLACED" ] \
    && [ "$(cat "$WEBHOOK_ATTACK_OUTSIDE/capture.err")" \
        = outside-capture-error-sentinel ] \
    && [ ! -e "$WEBHOOK_ATTACK_OUTSIDE/ready" ] \
    && [ ! -e "$WEBHOOK_ATTACK_OUTSIDE/event.json" ]; then
    pass "a retargeted evidence name causes no write outside the bound object"
else
    fail "the webhook evidence path followed a retargeted directory"
fi

info "webhook cleanup preserves a same-name replacement and displaced evidence"
rm -rf -- "$WEBHOOK_ATTACK_OUTSIDE" "$WEBHOOK_ATTACK_DISPLACED" \
    "$WEBHOOK_ATTACK_REPLACEMENT"
mkdir -p "$WEBHOOK_ATTACK_REPLACEMENT"
printf '%s\n' 'preserve-cleanup-replacement' \
    > "$WEBHOOK_ATTACK_REPLACEMENT/cleanup-victim"
WEBHOOK_EVIDENCE_ATTACK=cleanup-replacement run_hello_world
cleanup_victim=$(find "$TMP" -type f -name cleanup-victim -print -quit)
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ -e "$WEBHOOK_ATTACK_MARKER" ] \
    && [ -d "$WEBHOOK_ATTACK_DISPLACED" ] \
    && [ -n "$cleanup_victim" ] \
    && [ "$(cat "$cleanup_victim")" = preserve-cleanup-replacement ] \
    && grep -Eqi 'cleanup|evidence|identity' <<<"$HELLO_OUTPUT"; then
    pass "cleanup retains both a replacement object and displaced evidence"
else
    fail "cleanup deleted a replacement or hid the evidence identity mismatch"
fi

info "webhook cleanup stays bound when the evidence parent name is replaced"
rm -rf -- "$WEBHOOK_ANCESTOR_PARENT" "$WEBHOOK_ANCESTOR_DISPLACED"
mkdir -m 700 "$WEBHOOK_ANCESTOR_PARENT"
WEBHOOK_TMPDIR="$WEBHOOK_ANCESTOR_PARENT" \
    WEBHOOK_EVIDENCE_ATTACK=cleanup-ancestor run_hello_world
ancestor_leaf=""
if ! ancestor_leaf=$(cat "$WEBHOOK_ANCESTOR_LEAF_FILE" 2>/dev/null); then :; fi
ancestor_victim="$WEBHOOK_ANCESTOR_PARENT/$ancestor_leaf/cleanup-victim"
if [ -e "$WEBHOOK_ATTACK_MARKER" ] \
    && [ -f "$ancestor_victim" ] \
    && [ "$(cat "$ancestor_victim")" = preserve-ancestor-replacement ]; then
    pass "cleanup does not mutate a replacement evidence-parent tree"
else
    fail "cleanup followed a replaced evidence-parent path"
fi
rm -rf -- "$WEBHOOK_ANCESTOR_PARENT" "$WEBHOOK_ANCESTOR_DISPLACED"

info "a partial legitimate readiness write is pending, not invalid evidence"
WEBHOOK_EVIDENCE_SCENARIO=partial-ready run_hello_world
if [ "$HELLO_STATUS" -eq 0 ] \
    && grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
    pass "readiness becomes visible only after its retained capability is complete"
else
    fail "a partial legitimate readiness write caused a false failure"
fi

info "webhook quarantine never overwrites a raced destination"
rm -rf -- "$WEBHOOK_SYSCALL_REPLACEMENT"
HELLO_PYTHONPATH="$WEBHOOK_SITE_PACKAGES" \
    WEBHOOK_FINAL_SYSCALL_ATTACK=quarantine-collision run_hello_world
quarantine_path=""
if ! quarantine_path=$(sed -n '1p' "$WEBHOOK_QUARANTINE_RECEIPT" 2>/dev/null); then :; fi
quarantine_receipt=""
if ! quarantine_receipt=$(sed -n '2p' "$WEBHOOK_QUARANTINE_RECEIPT" 2>/dev/null); then :; fi
quarantine_after=""
if [ -n "$quarantine_path" ] && [ -d "$quarantine_path" ]; then
    quarantine_after=$(python3 - "$quarantine_path" <<'PY'
import os
import sys
value = os.stat(sys.argv[1])
print(f"{value.st_dev}:{value.st_ino}")
PY
    )
fi
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ -n "$quarantine_receipt" ] \
    && [ "$quarantine_after" = "$quarantine_receipt" ]; then
    pass "a quarantine collision preserves the existing destination"
else
    fail "quarantine replaced or removed a raced destination"
fi

info "webhook cleanup never unlinks a final-syscall replacement"
rm -rf -- "$WEBHOOK_SYSCALL_REPLACEMENT"
printf '%s\n' 'preserve-unlink-replacement' > "$WEBHOOK_SYSCALL_REPLACEMENT"
chmod 600 "$WEBHOOK_SYSCALL_REPLACEMENT"
HELLO_PYTHONPATH="$WEBHOOK_SITE_PACKAGES" \
    WEBHOOK_FINAL_SYSCALL_ATTACK=unlink-swap run_hello_world
if [ -f "$WEBHOOK_SYSCALL_REPLACEMENT" ] \
    && [ "$(cat "$WEBHOOK_SYSCALL_REPLACEMENT")" \
        = preserve-unlink-replacement ]; then
    pass "cleanup preserves a replacement at the unlink boundary"
else
    fail "cleanup unlinked a replacement object"
fi

info "webhook cleanup never removes a final-syscall directory replacement"
rm -rf -- "$WEBHOOK_SYSCALL_REPLACEMENT"
mkdir -m 700 "$WEBHOOK_SYSCALL_REPLACEMENT"
HELLO_PYTHONPATH="$WEBHOOK_SITE_PACKAGES" \
    WEBHOOK_FINAL_SYSCALL_ATTACK=rmdir-swap run_hello_world
if [ -d "$WEBHOOK_SYSCALL_REPLACEMENT" ]; then
    pass "cleanup preserves a replacement at the rmdir boundary"
else
    fail "cleanup removed a replacement directory"
fi

info "a final-name replacement cannot substitute for retained event evidence"
WEBHOOK_EVIDENCE_SCENARIO=replace-final-names run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && ! grep -q 'Captured the exact webhook event' <<<"$HELLO_OUTPUT"; then
    pass "event validation reads the producer capability, not a replacement name"
else
    fail "a same-UID final-name replacement supplied accepted event evidence"
fi

info "webhook cleanup retires an escaped capture descendant"
HELLO_BASH_ENV="$KILL_SHIM" \
    WEBHOOK_EVIDENCE_SCENARIO=term-resistant-descendant \
    HELLO_HTTP_SCENARIO=webhook-rejected run_hello_world
webhook_descendant_pid=""
if ! webhook_descendant_pid=$(cat "$TMP/webhook-descendant.pid" 2>/dev/null); then :; fi
if [ "$HELLO_STATUS" -ne 0 ] \
    && [ -n "$webhook_descendant_pid" ] \
    && ! /bin/kill -0 "$webhook_descendant_pid" 2>/dev/null; then
    pass "capture containment proves descendant extinction"
else
    if [ -n "$webhook_descendant_pid" ]; then
        if ! /bin/kill -KILL "$webhook_descendant_pid" 2>/dev/null; then :; fi
    fi
    fail "a capture descendant escaped cleanup"
fi

info "webhook cleanup does not signal a reused worker PID"
HELLO_BASH_ENV="$KILL_SHIM" \
    WEBHOOK_REUSED_PID=1 \
    WEBHOOK_EVIDENCE_SCENARIO=ready-then-exit \
    HELLO_HTTP_SCENARIO=webhook-rejected run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && ! grep -q '^REUSED ' "$TMP/webhook-signals.log"; then
    pass "cleanup signals only its live containment receipt"
else
    fail "cleanup signaled a reused capture PID"
fi

info "compose startup binds canonical scope and delegates to bounded health checks"
COMPOSE_FILE="$FIXTURE/foreign-compose.yml" \
    COMPOSE_PROJECT_NAME=foreign-project \
    HELLO_HTTP_SCENARIO=agamemnon-wrong-body run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Fq \
        "compose --project-name odysseus -f $FIXTURE/docker-compose.e2e.yml up" \
        "$PODMAN_LOG" \
    && ! grep -Fq "$FIXTURE/foreign-compose.yml" "$PODMAN_LOG" \
    && ! grep -Eq '(^| )wait( |$)' "$PODMAN_LOG"; then
    pass "compose startup cannot be retargeted and contains no unbounded wait"
else
    fail "compose startup accepted ambient scope or invoked an unbounded wait"
fi

info "a complete response set reaches truthful completion without repository writes"
VARZ_SCENARIO=positive AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 run_hello_world
if [ "$HELLO_STATUS" -eq 0 ] \
    && grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT" \
    && [ "$(cat "$FIXTURE/.env")" = operator-owned-env ] \
    && ! grep -q ' up ' "$PODMAN_LOG"; then
    pass "positive NATS evidence completes without compose or config mutation"
else
    fail "valid controlled boundary responses did not complete safely"
fi

info "task polling exhausts its distinct 30-second budget"
HELLO_EXHAUSTION_SCENARIO=task run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Fq 'Task not completed after 30s' <<<"$HELLO_OUTPUT" \
    && request_exhaustion_matches \
        http://localhost:8080/v1/tasks 15 2; then
    pass "task polling stops after fifteen two-second request slots"
else
    fail "task polling did not preserve its 30-second exhaustion class"
fi

info "Grafana polling exhausts its distinct 30-second budget"
HELLO_EXHAUSTION_SCENARIO=grafana run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Fq 'Grafana not accessible after 30s' <<<"$HELLO_OUTPUT" \
    && request_exhaustion_matches \
        http://localhost:3001/api/health 6 5; then
    pass "Grafana polling stops after six five-second request slots"
else
    fail "Grafana polling did not preserve its 30-second exhaustion class"
fi

info "service polling exhausts its distinct 60-second budget"
HELLO_EXHAUSTION_SCENARIO=service run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -Fq 'Nestor did not become healthy after 60s' <<<"$HELLO_OUTPUT" \
    && request_exhaustion_matches \
        http://localhost:8081/v1/health 12 5; then
    pass "service polling stops after twelve five-second request slots"
else
    fail "service polling did not preserve its 60-second exhaustion class"
fi

info "NATS readiness requires HTTP 200 and the exact health body"
for scenario in nats-204 nats-redirect nats-wrong-body; do
    HELLO_HTTP_SCENARIO="$scenario" VARZ_SCENARIO=positive \
        AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 \
        run_hello_world
    if [ "$HELLO_STATUS" -ne 0 ] \
        && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
        pass "$scenario cannot become hello-world readiness"
    else
        fail "$scenario became hello-world completion"
    fi
done

info "the initial hello-world readiness decision requires the exact response"
for scenario in agamemnon-204 agamemnon-redirect agamemnon-wrong-body; do
    HELLO_HTTP_SCENARIO="$scenario" VARZ_SCENARIO=positive \
        AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 \
        run_hello_world
    if [ "$HELLO_STATUS" -ne 0 ] \
        && ! grep -q 'Stack already running' <<<"$HELLO_OUTPUT" \
        && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
        pass "$scenario cannot become the initial readiness decision"
    else
        fail "$scenario produced an initial readiness claim"
    fi
done

info "an accepted webhook requires its exact new NATS event"
WEBHOOK_EVIDENCE_SCENARIO=missing SUBJECTS_SCENARIO=historical \
    VARZ_SCENARIO=unchanged run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
    pass "accepted-without-publication cannot produce completion"
else
    fail "historical broker state concealed a missing webhook publication"
fi

WEBHOOK_EVIDENCE_SCENARIO=unrelated SUBJECTS_SCENARIO=unrelated \
    VARZ_SCENARIO=positive run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
    pass "an unrelated new event cannot satisfy webhook evidence"
else
    fail "unrelated subject traffic satisfied the webhook oracle"
fi

info "Prometheus evidence rejects wrong values, zero, comments, malformed samples, collisions, and non-finite values"
for scenario in not-one zero comment-only malformed collision nonfinite; do
    METRICS_SCENARIO="$scenario" VARZ_SCENARIO=positive \
        AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 \
        run_hello_world
    if [ "$HELLO_STATUS" -ne 0 ] \
        && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
        pass "$scenario Prometheus evidence fails closed"
    else
        fail "$scenario Prometheus evidence produced a completion receipt"
    fi
done

info "NATS message evidence rejects missing, zero, and non-integer values"
for scenario in missing zero malformed; do
    VARZ_SCENARIO="$scenario" AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 run_hello_world
    if [ "$HELLO_STATUS" -ne 0 ] \
        && grep -q 'NATS' <<<"$HELLO_OUTPUT" \
        && ! grep -q 'ALL E2E CHECKS PASSED' <<<"$HELLO_OUTPUT"; then
        pass "$scenario in_msgs evidence fails closed"
    else
        fail "$scenario in_msgs evidence produced completion or lost its diagnostic"
    fi
done

info "hostile API identifiers stop before use at later request boundaries"
AGENT_ID_VALUE='../agent' TEAM_ID_VALUE=team-1 TASK_ID_VALUE=task-1 VARZ_SCENARIO=positive run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -q 'unsafe or missing identifier' <<<"$HELLO_OUTPUT" \
    && ! grep -Fq '/v1/agents/../agent/start' "$CURL_LOG"; then
    pass "hostile agent identifier is not placed in a URL"
else
    fail "hostile agent identifier crossed the next HTTP boundary"
fi

AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE='../team' TASK_ID_VALUE=task-1 VARZ_SCENARIO=positive run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -q 'unsafe or missing identifier' <<<"$HELLO_OUTPUT" \
    && ! grep -Fq '/v1/teams/../team/tasks' "$CURL_LOG"; then
    pass "hostile team identifier is not placed in a URL"
else
    fail "hostile team identifier crossed the next HTTP boundary"
fi

AGENT_ID_VALUE=agent-1 TEAM_ID_VALUE=team-1 TASK_ID_VALUE='bad/task' VARZ_SCENARIO=positive run_hello_world
if [ "$HELLO_STATUS" -ne 0 ] \
    && grep -q 'unsafe or missing identifier' <<<"$HELLO_OUTPUT" \
    && ! grep -Fq 'http://localhost:8080/v1/tasks' "$CURL_LOG"; then
    pass "hostile task identifier stops before status polling"
else
    fail "hostile task identifier reached the task-status boundary"
fi

summary
exit_code
