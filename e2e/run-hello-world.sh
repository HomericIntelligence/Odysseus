#!/usr/bin/env bash
# HomericIntelligence E2E Hello World Test
# Validates the complete pipeline: Hermes → NATS → Agamemnon → Myrmidon → Observability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ODYSSEUS_ROOT/docker-compose.e2e.yml"
STACK_PROJECT=odysseus
STACK_NETWORK=odysseus_homeric-mesh
# shellcheck source=e2e/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Resolve symlink paths for podman (can't follow symlinks as build contexts)
PROJECT_ROOT="$ODYSSEUS_ROOT"
HERMES_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/Hermes")"
ARGUS_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/Argus")"
MYRMIDONS_DIR="$(readlink -f "$ODYSSEUS_ROOT/provisioning/Myrmidons")"
PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
PROMETHEUS_CONFIG="$ODYSSEUS_ROOT/e2e/prometheus.yml"
export PROJECT_ROOT HERMES_DIR ARGUS_DIR MYRMIDONS_DIR PODMAN_SOCK PROMETHEUS_CONFIG

# Detect compose command
COMPOSE_CMD=()
CONTAINER_RUNTIME=""
if command -v podman &>/dev/null && podman compose version &>/dev/null 2>&1; then
  COMPOSE_CMD=(podman compose)
  CONTAINER_RUNTIME=podman
elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
  CONTAINER_RUNTIME=docker
else
  echo "ERROR: Neither 'podman compose' nor 'docker compose' found" >&2
  exit 1
fi

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
STACK_OWNERSHIP_VERIFIED=false
OWNED_STACK_IDS=()
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() {
  echo -e "  ${RED}✗ FAIL${NC}: $1"
  echo ""
  if [ "$STACK_OWNERSHIP_VERIFIED" != true ] \
      || ! require_owned_stack >/dev/null 2>&1; then
    STACK_OWNERSHIP_VERIFIED=false
    echo "Logs suppressed: stack ownership was not established."
    exit 1
  fi
  echo "Logs from owned stack containers:"
  if ! emit_owned_stack_logs; then
    echo "  (could not capture every owned container log)"
  fi
  exit 1
}
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

STACK_CONTAINERS=(
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
STACK_SERVICES=(
  nats
  agamemnon
  nestor
  hermes
  prometheus
  loki
  grafana
  argus-exporter
  hello-myrmidon
)
PREFLIGHT_CONTAINER_IDS=()

# Return one immutable identity-and-ownership receipt for an expected stack
# container. Both the reserved name and its immutable ID are checked by the
# caller so a same-name replacement cannot inherit the first observation.
stack_container_receipt() {
  local target="$1" expected_name="$2" expected_service="$3"
  local required_id="${4:-}" format receipt
  local container_id actual_name docker_project docker_service
  local podman_project podman_service extra ownership_count=0
  format='{{.Id}}|{{.Name}}|{{if index .Config.Labels "com.docker.compose.project"}}{{index .Config.Labels "com.docker.compose.project"}}{{end}}|{{if index .Config.Labels "com.docker.compose.service"}}{{index .Config.Labels "com.docker.compose.service"}}{{end}}|{{if index .Config.Labels "io.podman.compose.project"}}{{index .Config.Labels "io.podman.compose.project"}}{{end}}|{{if index .Config.Labels "io.podman.compose.service"}}{{index .Config.Labels "io.podman.compose.service"}}{{end}}'
  if ! receipt="$("$CONTAINER_RUNTIME" inspect --format "$format" \
      "$target" 2>/dev/null)" || [[ "$receipt" == *$'\n'* ]]; then
    return 1
  fi
  IFS='|' read -r container_id actual_name docker_project docker_service \
    podman_project podman_service extra <<<"$receipt"
  if [ -n "${extra:-}" ] || ! [[ "$container_id" =~ ^[0-9A-Fa-f]{64}$ ]] \
      || { [ "$actual_name" != "$expected_name" ] \
          && [ "$actual_name" != "/$expected_name" ]; } \
      || { [ -n "$required_id" ] && [ "$container_id" != "$required_id" ]; }; then
    return 1
  fi
  if [ -n "$docker_project" ] || [ -n "$docker_service" ]; then
    [ "$docker_project" = "$STACK_PROJECT" ] \
      && [ "$docker_service" = "$expected_service" ] || return 1
    ownership_count=$((ownership_count + 1))
  fi
  if [ -n "$podman_project" ] || [ -n "$podman_service" ]; then
    [ "$podman_project" = "$STACK_PROJECT" ] \
      && [ "$podman_service" = "$expected_service" ] || return 1
    ownership_count=$((ownership_count + 1))
  fi
  [ "$ownership_count" -gt 0 ] || return 1
  printf '%s\n' "$receipt"
}

stack_network_receipt() {
  local target="$1" required_id="${2:-}" format receipt
  local network_id actual_name docker_project docker_network
  local podman_project podman_network extra ownership_count=0
  if [ "$CONTAINER_RUNTIME" = podman ]; then
    format='{{.ID}}|{{.Name}}|{{if index .Labels "com.docker.compose.project"}}{{index .Labels "com.docker.compose.project"}}{{end}}|{{if index .Labels "com.docker.compose.network"}}{{index .Labels "com.docker.compose.network"}}{{end}}|{{if index .Labels "io.podman.compose.project"}}{{index .Labels "io.podman.compose.project"}}{{end}}|{{if index .Labels "io.podman.compose.network"}}{{index .Labels "io.podman.compose.network"}}{{end}}'
  else
    format='{{.Id}}|{{.Name}}|{{if index .Labels "com.docker.compose.project"}}{{index .Labels "com.docker.compose.project"}}{{end}}|{{if index .Labels "com.docker.compose.network"}}{{index .Labels "com.docker.compose.network"}}{{end}}|{{if index .Labels "io.podman.compose.project"}}{{index .Labels "io.podman.compose.project"}}{{end}}|{{if index .Labels "io.podman.compose.network"}}{{index .Labels "io.podman.compose.network"}}{{end}}'
  fi
  if ! receipt="$("$CONTAINER_RUNTIME" network inspect --format "$format" \
      "$target" 2>/dev/null)" || [[ "$receipt" == *$'\n'* ]]; then
    return 1
  fi
  IFS='|' read -r network_id actual_name docker_project docker_network \
    podman_project podman_network extra <<<"$receipt"
  if [ -n "${extra:-}" ] || ! [[ "$network_id" =~ ^[0-9A-Fa-f]{64}$ ]] \
      || [ "$actual_name" != "$STACK_NETWORK" ] \
      || { [ -n "$required_id" ] && [ "$network_id" != "$required_id" ]; }; then
    return 1
  fi
  if [ -n "$docker_project" ] || [ -n "$docker_network" ]; then
    [ "$docker_project" = "$STACK_PROJECT" ] \
      && [ "$docker_network" = homeric-mesh ] || return 1
    ownership_count=$((ownership_count + 1))
  fi
  if [ -n "$podman_project" ] || [ -n "$podman_network" ]; then
    [ "$podman_project" = "$STACK_PROJECT" ] \
      && [ "$podman_network" = homeric-mesh ] || return 1
    ownership_count=$((ownership_count + 1))
  fi
  [ "$ownership_count" -gt 0 ] || return 1
  printf '%s\n' "$receipt"
}

probe_stack_container() {
  local target="$1" probe_status
  if [ "$CONTAINER_RUNTIME" = podman ]; then
    podman container exists "$target" >/dev/null 2>&1
    return $?
  fi
  if docker container inspect "$target" >/dev/null 2>&1; then
    return 0
  else
    probe_status=$?
  fi
  if ! docker ps -a >/dev/null 2>&1; then
    return 125
  fi
  [ "$probe_status" -eq 1 ] && return 1
  return "$probe_status"
}

probe_stack_network() {
  local target="$1" probe_status
  if [ "$CONTAINER_RUNTIME" = podman ]; then
    podman network exists "$target" >/dev/null 2>&1
    return $?
  fi
  if docker network inspect "$target" >/dev/null 2>&1; then
    return 0
  else
    probe_status=$?
  fi
  if ! docker network ls >/dev/null 2>&1; then
    return 125
  fi
  [ "$probe_status" -eq 1 ] && return 1
  return "$probe_status"
}

project_container_inventory_is_bound() {
  local label_key inventory inventory_id bound_id matched
  for label_key in com.docker.compose.project io.podman.compose.project; do
    if ! inventory="$("$CONTAINER_RUNTIME" ps -a --no-trunc \
        --filter "label=$label_key=$STACK_PROJECT" \
        --format '{{.ID}}' 2>/dev/null)"; then
      echo "ERROR: cannot inventory $STACK_PROJECT project containers" >&2
      return 1
    fi
    while IFS= read -r inventory_id; do
      [ -n "$inventory_id" ] || continue
      if ! [[ "$inventory_id" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        echo "ERROR: project container inventory returned a mutable identity" >&2
        return 1
      fi
      matched=false
      for bound_id in "${PREFLIGHT_CONTAINER_IDS[@]}"; do
        if [ -n "$bound_id" ] && [ "$inventory_id" = "$bound_id" ]; then
          matched=true
          break
        fi
      done
      if [ "$matched" = false ]; then
        echo "ERROR: unbound $STACK_PROJECT project container $inventory_id" >&2
        return 1
      fi
    done <<<"$inventory"
  done
}

# Before Compose can create or replace anything, prove that every occupied
# reserved name already belongs to this project. Absence is allowed so a clean
# machine can start the stack; probe errors and foreign occupants fail closed.
preflight_stack_mutation() {
  local index container_name service_name probe_status
  local receipt container_id confirmed network_receipt network_id
  PREFLIGHT_CONTAINER_IDS=()
  for ((index = 0; index < ${#STACK_CONTAINERS[@]}; index++)); do
    container_name="${STACK_CONTAINERS[$index]}"
    service_name="${STACK_SERVICES[$index]}"
    if probe_stack_container "$container_name"; then
      if ! receipt="$(stack_container_receipt "$container_name" \
          "$container_name" "$service_name")"; then
        echo "ERROR: $container_name is foreign or lacks an ownership receipt" >&2
        return 1
      fi
      container_id="${receipt%%|*}"
      PREFLIGHT_CONTAINER_IDS[index]="$container_id"
      if ! confirmed="$(stack_container_receipt "$container_id" \
          "$container_name" "$service_name" "$container_id")" \
          || [ "$confirmed" != "$receipt" ] \
          || ! confirmed="$(stack_container_receipt "$container_name" \
              "$container_name" "$service_name" "$container_id")" \
          || [ "$confirmed" != "$receipt" ]; then
        echo "ERROR: $container_name changed during ownership preflight" >&2
        return 1
      fi
    else
      probe_status=$?
      if [ "$probe_status" -ne 1 ]; then
        echo "ERROR: cannot determine ownership for $container_name" >&2
        return 1
      fi
      PREFLIGHT_CONTAINER_IDS[index]=""
    fi
  done

  project_container_inventory_is_bound || return 1

  if probe_stack_network "$STACK_NETWORK"; then
    if ! network_receipt="$(stack_network_receipt "$STACK_NETWORK")"; then
      echo "ERROR: $STACK_NETWORK is foreign or lacks an ownership receipt" >&2
      return 1
    fi
    network_id="${network_receipt%%|*}"
    if ! confirmed="$(stack_network_receipt "$network_id" "$network_id")" \
        || [ "$confirmed" != "$network_receipt" ] \
        || ! confirmed="$(stack_network_receipt "$STACK_NETWORK" \
            "$network_id")" \
        || [ "$confirmed" != "$network_receipt" ]; then
      echo "ERROR: $STACK_NETWORK changed during ownership preflight" >&2
      return 1
    fi
  else
    probe_status=$?
    if [ "$probe_status" -ne 1 ]; then
      echo "ERROR: cannot determine ownership for $STACK_NETWORK" >&2
      return 1
    fi
  fi
}

require_owned_stack() {
  local index container_name service_name receipt container_id confirmed
  local -a verified_ids=()
  OWNED_STACK_IDS=()
  for ((index = 0; index < ${#STACK_CONTAINERS[@]}; index++)); do
    container_name="${STACK_CONTAINERS[$index]}"
    service_name="${STACK_SERVICES[$index]}"
    if ! receipt="$(stack_container_receipt "$container_name" \
        "$container_name" "$service_name")"; then
      echo "ERROR: $container_name is missing, foreign, or lacks an ownership receipt" >&2
      return 1
    fi
    container_id="${receipt%%|*}"
    if ! confirmed="$(stack_container_receipt "$container_id" \
        "$container_name" "$service_name" "$container_id")" \
        || [ "$confirmed" != "$receipt" ]; then
      echo "ERROR: $container_name changed while its ownership was being bound" >&2
      return 1
    fi
    verified_ids[index]="$container_id"
  done
  OWNED_STACK_IDS=("${verified_ids[@]}")
}

emit_owned_stack_logs() {
  local index container_id log_failed=0
  if [ "${#OWNED_STACK_IDS[@]}" -ne "${#STACK_CONTAINERS[@]}" ]; then
    return 1
  fi
  for ((index = 0; index < ${#OWNED_STACK_IDS[@]}; index++)); do
    container_id="${OWNED_STACK_IDS[$index]}"
    if ! [[ "$container_id" =~ ^[0-9A-Fa-f]{64}$ ]]; then
      return 1
    fi
  done
  for container_id in "${OWNED_STACK_IDS[@]}"; do
    if ! "$CONTAINER_RUNTIME" logs --tail 50 "$container_id" 2>&1; then
      log_failed=1
    fi
  done
  [ "$log_failed" -eq 0 ]
}

# Return success only when one exact Prometheus series has the required value.
# The optional label text is the complete label set without its braces.
prometheus_sample_matches() {
  local metric_name="$1" comparison="$2" label_text="${3:-}"
  python3 -c '
import math
import re
import sys

metric_name, comparison, label_text = sys.argv[1:]
if label_text:
    series = re.escape(f"{metric_name}{{{label_text}}}")
else:
    series = re.escape(metric_name) + r"(?:\{\})?"
number = r"[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?)|(?:\.[0-9]+))(?:[eE][+-]?[0-9]+)?"
sample = re.compile(rf"^{series}[ \t]+({number})(?:[ \t]+[+-]?[0-9]+)?[ \t]*$")

values = []
for line in sys.stdin:
    match = sample.fullmatch(line.rstrip("\r\n"))
    if match:
        value = float(match.group(1))
        if math.isfinite(value):
            values.append(value)

if len(values) != 1:
    sys.exit(1)
value = values[0]
if comparison == "one":
    sys.exit(0 if value == 1 else 1)
if comparison == "positive":
    sys.exit(0 if value > 0 else 1)
sys.exit(2)
' "$metric_name" "$comparison" "$label_text"
}

nats_in_msgs() {
  curl_bounded 15 -sf http://localhost:8222/varz | python3 -c '
import json
import sys
value = json.load(sys.stdin).get("in_msgs")
if type(value) is not int or value < 0:
    raise SystemExit(1)
print(value)
'
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence E2E Hello World Validation          ║"
echo "║  Pipeline: Hermes → NATS → Agamemnon → Myrmidon → Argus ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Phase 1: Start Stack ──────────────────────────────────────────────────
info "Phase 1: Starting E2E stack"
cd "$ODYSSEUS_ROOT"
if curl_http_response 15 http://localhost:8080/v1/health 2>/dev/null \
  | http_response_matches status; then
  echo "  Stack already running — skipping compose up."
else
  if ! preflight_stack_mutation; then
    fail "Stack ownership preflight failed before Compose startup"
  fi
  "${COMPOSE_CMD[@]}" --project-name "$STACK_PROJECT" \
    -f "$COMPOSE_FILE" up -d --build 2>&1 | tail -20
  echo "  Waiting for services to be healthy..."
  sleep 5
fi

if require_owned_stack; then
  STACK_OWNERSHIP_VERIFIED=true
  pass "All stack containers have stable odysseus ownership receipts"
else
  fail "Stack ownership could not be established before diagnostics or requests"
fi

# ─── Phase 2: Health Checks ───────────────────────────────────────────────
info "Phase 2: Service health checks"

if ! wait_for http://localhost:8080/v1/health Agamemnon 60 5; then
  fail "Agamemnon did not become healthy after 60s"
fi
if curl_http_response 15 http://localhost:8080/v1/health \
  | http_response_matches status; then
  pass "Agamemnon :8080/v1/health → {\"status\":\"ok\"}"
else
  fail "Agamemnon health check failed"
fi

if ! wait_for http://localhost:8081/v1/health Nestor 60 5; then
  fail "Nestor did not become healthy after 60s"
fi
if curl_http_response 15 http://localhost:8081/v1/health \
  | http_response_matches status; then
  pass "Nestor :8081/v1/health → {\"status\":\"ok\"}"
else
  fail "Nestor health check failed"
fi

if ! wait_for http://localhost:8085/health Hermes 60 5; then
  fail "Hermes did not become healthy after 60s"
fi
if curl_http_response 15 http://localhost:8085/health \
  | http_response_matches status; then
  pass "Hermes :8085/health → {\"status\":\"ok\"}"
else
  fail "Hermes health check failed"
fi

if curl_http_response 15 http://localhost:8222/healthz \
  | http_response_matches nats; then
  pass "NATS :8222/healthz → OK"
else
  fail "NATS health check failed"
fi

# ─── Phase 3: Hermes Webhook → NATS ──────────────────────────────────────
info "Phase 3: Webhook through Hermes → NATS"

EXPECTED_WEBHOOK_SUBJECT=hi.tasks.e2e-team.e2e-webhook-task.updated
if ! NATS_BEFORE_WEBHOOK=$(nats_in_msgs); then
  fail "Cannot capture the pre-webhook NATS message baseline"
fi

WEBHOOK_EVIDENCE_DIR=""
WEBHOOK_EVIDENCE_RECEIPT=""
WEBHOOK_CAPTURE_PID=""
webhook_bind_evidence() {
  local evidence_parent initial_receipt
  if ! evidence_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P); then
    printf '%s\n' 'ERROR: could not resolve the webhook evidence parent' >&2
    return 1
  fi
  if ! WEBHOOK_EVIDENCE_DIR=$(mktemp -d \
      "$evidence_parent/odysseus-webhook-evidence.XXXXXX"); then
    printf '%s\n' 'ERROR: could not create the webhook evidence directory' >&2
    return 1
  fi
  if ! initial_receipt=$(python3 - "$WEBHOOK_EVIDENCE_DIR" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
metadata = os.lstat(path)
if (
    not os.path.isabs(path)
    or not stat.S_ISDIR(metadata.st_mode)
    or metadata.st_uid != os.getuid()
    or stat.S_IMODE(metadata.st_mode) & 0o077
    or metadata.st_nlink < 1
):
    raise SystemExit(1)
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
  ); then
    printf 'ERROR: unsafe webhook evidence directory name: %s\n' \
      "$WEBHOOK_EVIDENCE_DIR" >&2
    return 1
  fi
  if ! exec 7< "$WEBHOOK_EVIDENCE_DIR"; then
    printf 'ERROR: could not retain webhook evidence directory: %s\n' \
      "$WEBHOOK_EVIDENCE_DIR" >&2
    return 1
  fi
  if ! python3 - "$WEBHOOK_EVIDENCE_DIR" "$initial_receipt" <<'PY'
import os
import stat
import sys

path, receipt = sys.argv[1:]
expected = tuple(map(int, receipt.split(":")))
opened = os.fstat(7)
named = os.lstat(path)
if (
    (opened.st_dev, opened.st_ino) != expected
    or (named.st_dev, named.st_ino) != expected
    or not stat.S_ISDIR(opened.st_mode)
    or not stat.S_ISDIR(named.st_mode)
    or opened.st_uid != os.getuid()
    or named.st_uid != os.getuid()
    or stat.S_IMODE(opened.st_mode) & 0o077
    or stat.S_IMODE(named.st_mode) & 0o077
    or opened.st_nlink < 1
):
    raise SystemExit(1)
PY
  then
    exec 7<&-
    printf 'ERROR: webhook evidence directory changed while binding: %s\n' \
      "$WEBHOOK_EVIDENCE_DIR" >&2
    return 1
  fi
  WEBHOOK_EVIDENCE_RECEIPT="$initial_receipt"
}

webhook_evidence_ready() {
  python3 - <<'PY'
import os
import stat

try:
    descriptor = os.open(
        "ready",
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=7,
    )
except FileNotFoundError:
    raise SystemExit(1)
try:
    opened = os.fstat(descriptor)
    named = os.stat("ready", dir_fd=7, follow_symlinks=False)
    value = os.read(descriptor, 7)
    trailing = os.read(descriptor, 1)
    named_after = os.stat("ready", dir_fd=7, follow_symlinks=False)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.getuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or (opened.st_dev, opened.st_ino)
        != (named.st_dev, named.st_ino)
        or (opened.st_dev, opened.st_ino)
        != (named_after.st_dev, named_after.st_ino)
        or value != b"ready\n"
        or trailing
    ):
        raise SystemExit(2)
finally:
    os.close(descriptor)
PY
}

webhook_validate_event() {
  local expected_subject="$1" expected_request_id="$2"
  python3 - "$expected_subject" "$expected_request_id" <<'PY'
import json
import os
import stat
import sys

expected_subject, expected_request_id = sys.argv[1:]
descriptor = os.open(
    "event.json",
    os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    dir_fd=7,
)
try:
    opened = os.fstat(descriptor)
    named = os.stat("event.json", dir_fd=7, follow_symlinks=False)
    value = os.read(descriptor, 1024 * 1024 + 1)
    named_after = os.stat("event.json", dir_fd=7, follow_symlinks=False)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.getuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or len(value) > 1024 * 1024
        or (opened.st_dev, opened.st_ino)
        != (named.st_dev, named.st_ino)
        or (opened.st_dev, opened.st_ino)
        != (named_after.st_dev, named_after.st_ino)
    ):
        raise SystemExit(1)
finally:
    os.close(descriptor)

evidence = json.loads(value)
payload = evidence.get("payload") if isinstance(evidence, dict) else None
data = payload.get("data") if isinstance(payload, dict) else None
if (
    evidence.get("subject") != expected_subject
    or payload.get("schema_version") != 1
    or payload.get("event") != "task.updated"
    or payload.get("request_id") != expected_request_id
    or not isinstance(data, dict)
    or data.get("team_id") != "e2e-team"
    or data.get("task_id") != "e2e-webhook-task"
):
    raise SystemExit(1)
PY
}

webhook_cleanup_bound_evidence() {
  python3 - "$WEBHOOK_EVIDENCE_DIR" "$WEBHOOK_EVIDENCE_RECEIPT" <<'PY'
import os
import secrets
import stat
import sys

path, receipt = sys.argv[1:]
expected = tuple(map(int, receipt.split(":")))
parent, leaf = os.path.split(path)


def open_directory_chain(value: str) -> int:
    if not os.path.isabs(value):
        raise RuntimeError("evidence parent is not absolute")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in (item for item in value.split("/") if item):
            next_descriptor = os.open(
                component,
                os.O_RDONLY
                | os.O_DIRECTORY
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


parent_fd = open_directory_chain(parent)
quarantine = f".{leaf}.quarantine-{secrets.token_hex(12)}"
try:
    opened_directory = os.fstat(7)
    if (opened_directory.st_dev, opened_directory.st_ino) != expected:
        raise RuntimeError("retained evidence descriptor identity changed")
    os.rename(
        leaf,
        quarantine,
        src_dir_fd=parent_fd,
        dst_dir_fd=parent_fd,
    )
    quarantined = os.stat(
        quarantine, dir_fd=parent_fd, follow_symlinks=False
    )
    if (
        (quarantined.st_dev, quarantined.st_ino) != expected
        or not stat.S_ISDIR(quarantined.st_mode)
    ):
        raise RuntimeError(
            f"evidence name identity mismatch; preserved as {parent}/{quarantine}"
        )
    names = os.listdir(7)
    unexpected = sorted(set(names) - {"ready", "event.json"})
    if unexpected:
        raise RuntimeError(
            f"unexpected evidence entries preserved as {parent}/{quarantine}"
        )
    for name in names:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=7,
        )
        try:
            opened = os.fstat(descriptor)
            named = os.stat(name, dir_fd=7, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.getuid()
                or opened.st_nlink != 1
                or stat.S_IMODE(opened.st_mode) != 0o600
                or (opened.st_dev, opened.st_ino)
                != (named.st_dev, named.st_ino)
            ):
                raise RuntimeError(
                    f"unsafe evidence entry preserved as {parent}/{quarantine}"
                )
            os.unlink(name, dir_fd=7)
            after = os.fstat(descriptor)
            if (
                (after.st_dev, after.st_ino)
                != (opened.st_dev, opened.st_ino)
                or after.st_nlink != 0
            ):
                raise RuntimeError("evidence unlink identity was not proven")
        finally:
            os.close(descriptor)
    final_name = os.stat(
        quarantine, dir_fd=parent_fd, follow_symlinks=False
    )
    if (
        (final_name.st_dev, final_name.st_ino) != expected
        or os.listdir(7)
    ):
        raise RuntimeError(
            f"evidence quarantine changed; preserved as {parent}/{quarantine}"
        )
    os.rmdir(quarantine, dir_fd=parent_fd)
except BaseException as error:
    print(f"ERROR: webhook evidence cleanup failed: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    os.close(parent_fd)
PY
}

if ! webhook_bind_evidence; then
  fail "Could not bind a private webhook evidence directory"
fi

wait_for_webhook_capture_exit() {
  local attempt
  for ((attempt = 0; attempt < 20; attempt++)); do
    if ! kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
      return 0
    fi
    if ! python3 -c 'import time; time.sleep(0.01)'; then
      return 2
    fi
  done
  return 1
}

stop_webhook_capture() {
  local grace_status wait_status
  [ -n "$WEBHOOK_CAPTURE_PID" ] || return 0

  if kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
    if ! kill -TERM "$WEBHOOK_CAPTURE_PID" 2>/dev/null \
        && kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
      printf 'ERROR: could not terminate webhook capture child %s\n' \
        "$WEBHOOK_CAPTURE_PID" >&2
      return 1
    fi

    if wait_for_webhook_capture_exit; then
      :
    else
      grace_status=$?
      if [ "$grace_status" -ne 1 ]; then
        printf 'ERROR: could not observe webhook capture child %s\n' \
          "$WEBHOOK_CAPTURE_PID" >&2
        return 1
      fi
      if ! kill -KILL "$WEBHOOK_CAPTURE_PID" 2>/dev/null \
          && kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
        printf 'ERROR: webhook capture child %s survived TERM and KILL failed\n' \
          "$WEBHOOK_CAPTURE_PID" >&2
        return 1
      fi
    fi
  fi

  if wait "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
    wait_status=0
  else
    wait_status=$?
  fi
  if [ "$wait_status" -eq 127 ]; then
    printf 'ERROR: could not reap webhook capture child %s\n' \
      "$WEBHOOK_CAPTURE_PID" >&2
    return 1
  fi
  if kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
    printf 'ERROR: webhook capture child %s remains after reap\n' \
      "$WEBHOOK_CAPTURE_PID" >&2
    return 1
  fi
  WEBHOOK_CAPTURE_PID=""
}

cleanup_webhook_evidence() {
  if ! stop_webhook_capture; then
    printf 'ERROR: retained webhook evidence after cleanup failure: %s\n' \
      "$WEBHOOK_EVIDENCE_DIR" >&2
    return 1
  fi
  if ! webhook_cleanup_bound_evidence; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
}

cleanup_webhook_evidence_on_exit() {
  local prior_status="$1" cleanup_status=0
  trap - EXIT
  if cleanup_webhook_evidence; then
    :
  else
    cleanup_status=$?
  fi
  if [ "$prior_status" -ne 0 ]; then
    exit "$prior_status"
  fi
  exit "$cleanup_status"
}
trap 'cleanup_webhook_evidence_on_exit "$?"' EXIT
python3 "$SCRIPT_DIR/capture-nats-event.py" \
  --host 127.0.0.1 --port 4222 \
  --subject "$EXPECTED_WEBHOOK_SUBJECT" --event task.updated \
  --team-id e2e-team --task-id e2e-webhook-task \
  --evidence-dir-fd 7 --ready-name ready --output-name event.json \
  --timeout 10 &
WEBHOOK_CAPTURE_PID=$!
WEBHOOK_READY_STATUS=1
for _ in $(seq 1 200); do
  if webhook_evidence_ready; then
    WEBHOOK_READY_STATUS=0
    break
  else
    WEBHOOK_READY_STATUS=$?
    if [ "$WEBHOOK_READY_STATUS" -eq 2 ]; then
      break
    fi
  fi
  if ! kill -0 "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then
    break
  fi
  python3 -c 'import time; time.sleep(0.01)'
done
if [ "$WEBHOOK_READY_STATUS" -ne 0 ]; then
  if ! wait "$WEBHOOK_CAPTURE_PID" 2>/dev/null; then :; fi
  WEBHOOK_CAPTURE_PID=""
  fail "Exact NATS evidence consumer did not become ready"
fi

WEBHOOK_TS=$(date -u +%FT%TZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
WEBHOOK_RESP=$(curl_bounded 15 -sf -X POST http://localhost:8085/webhook \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"task.updated\",\"data\":{\"team_id\":\"e2e-team\",\"task_id\":\"e2e-webhook-task\"},\"timestamp\":\"$WEBHOOK_TS\"}")

if WEBHOOK_REQUEST_ID=$(printf '%s\n' "$WEBHOOK_RESP" | python3 -c '
import json
import sys
value = json.load(sys.stdin)
if value.get("status") != "accepted" or value.get("event") != "task.updated":
    raise SystemExit(1)
request_id = value.get("request_id")
if not isinstance(request_id, str) or not request_id:
    raise SystemExit(1)
print(request_id)
'); then
  pass "Webhook accepted: $WEBHOOK_RESP"
else
  fail "Webhook rejected: $WEBHOOK_RESP"
fi

if ! wait "$WEBHOOK_CAPTURE_PID"; then
  WEBHOOK_CAPTURE_PID=""
  fail "Accepted webhook produced no exact new NATS event"
fi
WEBHOOK_CAPTURE_PID=""
if webhook_validate_event "$EXPECTED_WEBHOOK_SUBJECT" \
    "$WEBHOOK_REQUEST_ID"; then
  pass "Captured the exact webhook event with request_id=$WEBHOOK_REQUEST_ID"
else
  fail "NATS event does not match the accepted webhook"
fi

SUBJECTS_RESP=$(curl_bounded 15 -sf http://localhost:8085/subjects)
if printf '%s\n' "$SUBJECTS_RESP" | python3 -c '
import json
import sys
subjects = json.load(sys.stdin).get("subjects")
expected = sys.argv[1]
if not isinstance(subjects, list) or subjects.count(expected) != 1:
    raise SystemExit(1)
' "$EXPECTED_WEBHOOK_SUBJECT"; then
  pass "Hermes tracked exact NATS subject: $EXPECTED_WEBHOOK_SUBJECT"
else
  fail "Hermes did not track the exact webhook subject"
fi

if ! NATS_AFTER_WEBHOOK=$(nats_in_msgs) \
    || ! python3 - "$NATS_BEFORE_WEBHOOK" "$NATS_AFTER_WEBHOOK" <<'PY'
import sys
before, after = map(int, sys.argv[1:])
raise SystemExit(0 if after > before else 1)
PY
then
  fail "NATS message count did not advance for the accepted webhook"
fi
pass "NATS message count advanced: $NATS_BEFORE_WEBHOOK -> $NATS_AFTER_WEBHOOK"
if ! cleanup_webhook_evidence; then
  trap - EXIT
  fail "Webhook evidence cleanup did not prove capture-child extinction"
fi
trap - EXIT

# ─── Phase 4: Agamemnon CRUD ─────────────────────────────────────────────
info "Phase 4: Create agent → team → task via Agamemnon"

# Create agent
AGENT_RESP=$(curl_bounded 15 -sf -X POST http://localhost:8080/v1/agents \
  -H "Content-Type: application/json" \
  -d '{"name":"hello-worker","label":"Hello Worker","program":"none","workingDirectory":"/tmp","taskDescription":"E2E test agent","tags":["e2e","hello"],"owner":"e2e-test","role":"member"}')
AGENT_ID=$(printf '%s\n' "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
if is_safe_identifier "$AGENT_ID"; then
  pass "Agent created: $AGENT_ID"
else
  fail "Agent creation returned an unsafe or missing identifier: $AGENT_RESP"
fi

# Start agent
START_RESP=$(curl_bounded 15 -sf -X POST "http://localhost:8080/v1/agents/${AGENT_ID}/start" \
  -H "Content-Type: application/json" -d '{}')
if printf '%s\n' "$START_RESP" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='online', f'Bad: {d}'"; then
  pass "Agent started: status=online"
else
  fail "Agent start failed: $START_RESP"
fi

# Verify agent appears in list
AGENTS_RESP=$(curl_bounded 15 -sf http://localhost:8080/v1/agents)
if printf '%s\n' "$AGENTS_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
agents=d.get('agents',[])
match=[a for a in agents if a.get('id')==sys.argv[1]]
assert len(match)==1, f'Agent not found in list: {d}'
assert match[0].get('status')=='online', f'Agent not online: {match[0]}'
print(f'  agents list: {len(agents)} total, target agent status={match[0][\"status\"]}')" \
  "$AGENT_ID"; then
  pass "Agent appears in /v1/agents with status=online"
else
  fail "Agent not found or not online in list"
fi

# Create team
TEAM_RESP=$(curl_bounded 15 -sf -X POST http://localhost:8080/v1/teams \
  -H "Content-Type: application/json" \
  -d '{"name":"hello-team"}')
TEAM_ID=$(printf '%s\n' "$TEAM_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('team',{}).get('id',''))")
if is_safe_identifier "$TEAM_ID"; then
  pass "Team created: $TEAM_ID"
else
  fail "Team creation returned an unsafe or missing identifier: $TEAM_RESP"
fi

# Create task → dispatches to hi.myrmidon.hello.{task_id}
TASK_RESP=$(curl_bounded 15 -sf -X POST "http://localhost:8080/v1/teams/${TEAM_ID}/tasks" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"Say hello world\",\"description\":\"Process a hello world message\",\"type\":\"hello\",\"assigneeAgentId\":\"${AGENT_ID}\"}")
TASK_ID=$(printf '%s\n' "$TASK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',{}).get('id',''))")
if is_safe_identifier "$TASK_ID"; then
  pass "Task created: $TASK_ID (dispatched to NATS hi.myrmidon.hello.*)"
else
  fail "Task creation returned an unsafe or missing identifier: $TASK_RESP"
fi

# ─── Phase 5: Wait for Myrmidon ──────────────────────────────────────────
info "Phase 5: Waiting for hello-myrmidon to process task"

MAX_WAIT=30; TASK_POLL_SECONDS=2
TASK_WAIT_START=$SECONDS; TASK_DEADLINE=$((SECONDS + MAX_WAIT))
TASK_ATTEMPT=0
TASK_MAX_ATTEMPTS=$(((MAX_WAIT + TASK_POLL_SECONDS - 1) / TASK_POLL_SECONDS))
ELAPSED=0; TASK_STATUS="pending"
while [ "$SECONDS" -lt "$TASK_DEADLINE" ] \
    && [ "$TASK_ATTEMPT" -lt "$TASK_MAX_ATTEMPTS" ]; do
  TASK_ATTEMPT=$((TASK_ATTEMPT + 1))
  TASK_REMAINING=$((TASK_DEADLINE - SECONDS))
  TASK_REQUEST_BUDGET="$TASK_POLL_SECONDS"
  if [ "$TASK_REQUEST_BUDGET" -gt "$TASK_REMAINING" ]; then
    TASK_REQUEST_BUDGET="$TASK_REMAINING"
  fi
  TASK_STATUS=$(curl_bounded "$TASK_REQUEST_BUDGET" -sf \
    "http://localhost:8080/v1/tasks" | \
    python3 -c 'import sys,json; tasks=json.load(sys.stdin).get("tasks",[]); match=[t for t in tasks if t.get("id")==sys.argv[1]]; print(match[0].get("status","unknown") if match else "not_found")' \
      "$TASK_ID" 2>/dev/null || echo "unknown")
  [ "$TASK_STATUS" = "completed" ] && break
  TASK_REMAINING=$((TASK_DEADLINE - SECONDS))
  [ "$TASK_REMAINING" -gt 0 ] || break
  TASK_SLEEP="$TASK_POLL_SECONDS"
  if [ "$TASK_SLEEP" -gt "$TASK_REMAINING" ]; then
    TASK_SLEEP="$TASK_REMAINING"
  fi
  sleep "$TASK_SLEEP"
done
ELAPSED=$((SECONDS - TASK_WAIT_START))
if [ "$TASK_STATUS" = "completed" ]; then
  pass "Myrmidon processed task in ${ELAPSED}s → status=completed"
else
  fail "Task not completed after ${MAX_WAIT}s (status=$TASK_STATUS). Check: podman compose logs hello-myrmidon"
fi

# ─── Phase 6: Observability ──────────────────────────────────────────────
info "Phase 6: Argus exporter metrics"

# Give exporter time to scrape
sleep 5
METRICS=$(curl_bounded 15 -sf http://localhost:9100/metrics 2>/dev/null) || { fail "Argus exporter not responding on :9100"; }

if printf '%s\n' "$METRICS" | prometheus_sample_matches hi_agamemnon_health one; then
  pass "Prometheus metric: hi_agamemnon_health=1"
else
  fail "hi_agamemnon_health not 1 (Agamemnon down?)"
fi
if printf '%s\n' "$METRICS" | prometheus_sample_matches hi_agents_total positive; then
  pass "Prometheus metric: hi_agents_total>0"
else
  fail "hi_agents_total is missing, malformed, or not positive"
fi
if printf '%s\n' "$METRICS" | prometheus_sample_matches hi_agents_online positive; then
  pass "Prometheus metric: hi_agents_online>0"
else
  fail "hi_agents_online is missing, malformed, or not positive"
fi
if printf '%s\n' "$METRICS" | prometheus_sample_matches hi_nestor_health one; then
  pass "Prometheus metric: hi_nestor_health=1"
else
  fail "hi_nestor_health not 1 (Nestor down?)"
fi
if printf '%s\n' "$METRICS" | prometheus_sample_matches hi_tasks_total positive; then
  pass "Prometheus metric: hi_tasks_total>0"
else
  fail "hi_tasks_total is missing, malformed, or not positive"
fi
if printf '%s\n' "$METRICS" \
  | prometheus_sample_matches hi_tasks_by_status positive 'status="completed"'; then
  pass "Prometheus metric: hi_tasks_by_status{status=\"completed\"}>0"
else
  fail "completed-task metric is missing, malformed, or not positive"
fi

# ─── Phase 7: NATS JetStream ─────────────────────────────────────────────
info "Phase 7: NATS JetStream verification"

VARZ=$(curl_bounded 15 -sf http://localhost:8222/varz)
if IN_MSGS=$(printf '%s\n' "$VARZ" | python3 -c \
  'import sys,json; value=json.load(sys.stdin).get("in_msgs"); print(value) if type(value) is int and value >= 0 else sys.exit(1)' \
  2>/dev/null) && python3 - "$NATS_AFTER_WEBHOOK" "$IN_MSGS" <<'PY'
import sys
minimum, current = map(int, sys.argv[1:])
raise SystemExit(0 if current >= minimum else 1)
PY
then
  pass "NATS processed $IN_MSGS messages total"
else
  fail "NATS did not retain the verified post-webhook message count (received: ${IN_MSGS:-invalid or missing})"
fi

# ─── Phase 8: Grafana ────────────────────────────────────────────────────
info "Phase 8: Grafana dashboard verification"

if ! wait_for http://localhost:3001/api/health Grafana 30 5; then
  fail "Grafana not accessible after 30s"
fi
if curl_http_response 15 http://localhost:3001/api/health \
  | http_response_matches grafana; then
  pass "Grafana running at http://localhost:3001 (database=ok)"
else
  fail "Grafana database not ok"
fi

# ─── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo -e "║  ${GREEN}ALL E2E CHECKS PASSED${NC}                                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Services (keep running for manual inspection):          ║"
echo "║    Agamemnon:   http://localhost:8080/v1/health          ║"
echo "║    Nestor:      http://localhost:8081/v1/health          ║"
echo "║    Hermes:      http://localhost:8085/health             ║"
echo "║    NATS:        http://localhost:8222                     ║"
echo "║    Prometheus:  http://localhost:9090                     ║"
echo "║    Grafana:     http://localhost:3001                     ║"
echo "║    Exporter:    http://localhost:9100/metrics            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  To tear down:  just e2e-down                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
