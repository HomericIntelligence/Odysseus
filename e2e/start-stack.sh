#!/usr/bin/env bash
# HomericIntelligence E2E Stack Launcher
# Handles podman rootless DNS issues by discovering container IPs
# and restarting NATS-dependent services with direct IP addresses.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ODYSSEUS_ROOT/docker-compose.e2e.yml"
# shellcheck source=e2e/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Resolve symlink paths for podman (can't follow symlinks as build contexts)
PROJECT_ROOT="$ODYSSEUS_ROOT"
HERMES_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/Hermes")"
ARGUS_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/Argus")"
MYRMIDONS_DIR="$(readlink -f "$ODYSSEUS_ROOT/provisioning/Myrmidons")"
PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
PROMETHEUS_CONFIG=""
PROMETHEUS_CONFIG_NAME=""
RUNTIME_DIRECTORY=""
RUNTIME_DIRECTORY_ID=""
PROMETHEUS_CONFIG_ID=""
PROMETHEUS_VOLUME_RECEIPT=""
STACK_PROJECT="odysseus"
STACK_NETWORK="odysseus_homeric-mesh"
STACK_NETWORK_ID=""
NATS_IP=""
AGAMEMNON_IP=""
NESTOR_IP=""

REQUIRED_CONTAINERS=(
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

REQUIRED_SERVICES=(
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

REQUIRED_IMAGE_REFS=(
  'nats:2.10@sha256:5498ba57b9471840be3d15b033a4eec554d1c02fa6c2cc0ca2d888637f6c6e2f'
  'odysseus-agamemnon:latest'
  'odysseus-nestor:latest'
  'odysseus-hermes:latest'
  'prom/prometheus:v3.1.0@sha256:6559acbd5d770b15bb3c954629ce190ac3cbbdb2b7f1c30f0385c4e05104e218'
  'grafana/loki:3.3.2@sha256:8af2de1abbdd7aa92b27c9bcc96f0f4140c9096b507c77921ffddf1c6ad6c48f'
  'grafana/grafana:11.4.0@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb'
  'odysseus-argus-exporter:latest'
  'odysseus-hello-myrmidon:latest'
)

EXPECTED_IMAGE_IDS=()
EXPECTED_IMAGE_VOLUMES=()
EXPECTED_IMAGE_CONFIGS=()
BOUND_CONTAINER_IDS=()
PREEXISTING_CONTAINER_IDS=()

json_field_equals() {
  local url="$1" field="$2" expected="$3" kind
  case "$field:$expected" in
    status:ok) kind=status ;;
    database:ok) kind=grafana ;;
    *) return 2 ;;
  esac
  curl_http_response 15 "$url" | http_response_matches "$kind"
}

container_is_running() {
  [ "$(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]
}

stack_is_ready() {
  local container_index
  command -v podman >/dev/null 2>&1 || return 1
  [ "${#BOUND_CONTAINER_IDS[@]}" -eq "${#REQUIRED_CONTAINERS[@]}" ] || return 1
  for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
    [ -n "${BOUND_CONTAINER_IDS[$container_index]:-}" ] || return 1
    container_is_running "${BOUND_CONTAINER_IDS[$container_index]}" || return 1
  done
  json_field_equals http://localhost:8080/v1/health status ok || return 1
  json_field_equals http://localhost:8081/v1/health status ok || return 1
  curl_http_response 15 http://localhost:8085/health \
    | http_response_matches hermes || return 1
  curl_http_response 15 http://localhost:8222/healthz \
    | http_response_matches nats || return 1
  curl_http_response 15 http://localhost:9090/-/healthy \
    | http_response_matches prometheus || return 1
  json_field_equals http://localhost:3001/api/health database ok || return 1
  curl_http_response 15 http://localhost:9100/metrics \
    | http_response_matches argus || return 1
  curl_http_response 15 http://localhost:8222/varz \
    | http_response_matches varz || return 1
}

runtime_config_transaction() {
  python3 - "$@" <<'PY'
import errno
import ipaddress
import os
import re
import secrets
import stat
import subprocess
import sys

CONFIG_NAME = "prometheus.runtime.yml"
CONFIG_NAME_PATTERN = re.compile(
    r"prometheus\.(?:runtime|resolved\.[0-9a-f]{24})\.yml"
)


def required_flag(name):
    value = getattr(os, name, None)
    if value is None:
        raise RuntimeError(f"platform does not provide {name}")
    return value


O_NOFOLLOW = required_flag("O_NOFOLLOW")
O_DIRECTORY = required_flag("O_DIRECTORY")
O_CLOEXEC = required_flag("O_CLOEXEC")


def identity(value):
    return f"{value.st_dev}:{value.st_ino}"


def read_all(fd):
    chunks = []
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def write_all(fd, payload):
    remaining = memoryview(payload)
    while remaining:
        written = os.write(fd, remaining)
        if written <= 0:
            raise OSError(errno.EIO, "short runtime-config write")
        remaining = remaining[written:]


def validate_runtime_stat(value, expected=None):
    if not stat.S_ISDIR(value.st_mode):
        raise RuntimeError("runtime path is not a direct directory")
    if value.st_uid != os.geteuid():
        raise RuntimeError("runtime directory is not owned by the invoking user")
    if stat.S_IMODE(value.st_mode) != 0o700:
        raise RuntimeError("runtime directory mode must be 0700")
    if expected is not None and identity(value) != expected:
        raise RuntimeError("runtime directory identity changed")


def validate_file_stat(value, expected=None, links=1):
    if not stat.S_ISREG(value.st_mode):
        raise RuntimeError("runtime config is not a regular file")
    if value.st_uid != os.geteuid():
        raise RuntimeError("runtime config is not owned by the invoking user")
    if stat.S_IMODE(value.st_mode) != 0o644:
        raise RuntimeError("runtime config mode must be 0644")
    if value.st_nlink != links:
        raise RuntimeError(f"runtime config link count must be {links}")
    if expected is not None and identity(value) != expected:
        raise RuntimeError("runtime config identity changed")


def open_runtime(path, expected=None):
    before = os.lstat(path)
    validate_runtime_stat(before, expected)
    fd = os.open(path, os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        validate_runtime_stat(opened, expected)
        if identity(before) != identity(opened):
            raise RuntimeError("runtime directory changed while opening")
        current = os.lstat(path)
        validate_runtime_stat(current, identity(opened))
        return fd, opened
    except Exception:
        os.close(fd)
        raise


def stat_name(directory_fd, name):
    return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)


def validate_named_file(directory_fd, name, expected, links=1):
    named = stat_name(directory_fd, name)
    validate_file_stat(named, expected, links)
    return named


def validate_config_name(name):
    if CONFIG_NAME_PATTERN.fullmatch(name) is None:
        raise RuntimeError("runtime config name is outside the owned namespace")


def revalidate_runtime(path, directory_fd, expected):
    opened = os.fstat(directory_fd)
    validate_runtime_stat(opened, expected)
    current = os.lstat(path)
    validate_runtime_stat(current, expected)


def unlink_bound(directory_fd, name, expected):
    current = stat_name(directory_fd, name)
    if identity(current) != expected:
        raise RuntimeError("refusing to unlink a replaced runtime temporary")
    os.unlink(name, dir_fd=directory_fd)


def open_trusted_source(path):
    fd = os.open(path, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try:
        value = os.fstat(fd)
        if not stat.S_ISREG(value.st_mode):
            raise RuntimeError("Prometheus source is not a regular file")
        return read_all(fd)
    finally:
        os.close(fd)


def create_temporary(directory_fd, prefix):
    for _ in range(128):
        name = f"{prefix}{secrets.token_hex(12)}"
        try:
            fd = os.open(
                name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o644,
                dir_fd=directory_fd,
            )
            # Keep the parent directory owner-private.  The bind source needs
            # read permission for Prometheus's non-owner container identity.
            os.fchmod(fd, 0o644)
            return name, fd
        except FileExistsError:
            continue
    raise RuntimeError("cannot allocate an exclusive runtime temporary")


def prepare(runtime_path, source_path):
    directory_fd = None
    temporary_fd = None
    temporary_name = None
    temporary_id = None
    published = False
    try:
        source = open_trusted_source(source_path)
        directory_fd, directory_stat = open_runtime(runtime_path)
        try:
            stat_name(directory_fd, CONFIG_NAME)
        except FileNotFoundError:
            pass
        else:
            raise RuntimeError("runtime config destination already exists")

        temporary_name, temporary_fd = create_temporary(
            directory_fd, ".prometheus.runtime."
        )
        write_all(temporary_fd, source)
        os.fsync(temporary_fd)
        temporary_stat = os.fstat(temporary_fd)
        validate_file_stat(temporary_stat)
        temporary_id = identity(temporary_stat)
        validate_named_file(directory_fd, temporary_name, temporary_id)

        os.link(
            temporary_name,
            CONFIG_NAME,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        published = True
        validate_named_file(directory_fd, temporary_name, temporary_id, links=2)
        validate_named_file(directory_fd, CONFIG_NAME, temporary_id, links=2)
        unlink_bound(directory_fd, temporary_name, temporary_id)
        temporary_name = None
        validate_named_file(directory_fd, CONFIG_NAME, temporary_id)
        revalidate_runtime(runtime_path, directory_fd, identity(directory_stat))
        os.fsync(directory_fd)
        print(identity(directory_stat), temporary_id)
    except Exception:
        if directory_fd is not None and temporary_id is not None:
            if published:
                try:
                    unlink_bound(directory_fd, CONFIG_NAME, temporary_id)
                except (FileNotFoundError, RuntimeError, OSError):
                    pass
            if temporary_name is not None:
                try:
                    unlink_bound(directory_fd, temporary_name, temporary_id)
                except (FileNotFoundError, RuntimeError, OSError):
                    pass
        raise
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        if directory_fd is not None:
            os.close(directory_fd)


def verify(runtime_path, directory_id, config_name, config_id):
    validate_config_name(config_name)
    directory_fd, _ = open_runtime(runtime_path, directory_id)
    try:
        config_fd = os.open(
            config_name,
            os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            dir_fd=directory_fd,
        )
        try:
            config_stat = os.fstat(config_fd)
            validate_file_stat(config_stat, config_id)
            validate_named_file(directory_fd, config_name, config_id)
            revalidate_runtime(runtime_path, directory_fd, directory_id)
        finally:
            os.close(config_fd)
    finally:
        os.close(directory_fd)


def adopt(config_path):
    if config_path != os.path.abspath(config_path):
        raise RuntimeError("adopted runtime config path is not absolute")
    runtime_path, config_name = os.path.split(config_path)
    validate_config_name(config_name)
    directory_fd, directory_stat = open_runtime(runtime_path)
    try:
        config_fd = os.open(
            config_name,
            os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC,
            dir_fd=directory_fd,
        )
        try:
            config_stat = os.fstat(config_fd)
            validate_file_stat(config_stat)
            config_id = identity(config_stat)
            validate_named_file(directory_fd, config_name, config_id)
            revalidate_runtime(runtime_path, directory_fd, identity(directory_stat))
            print(identity(directory_stat), config_id)
        finally:
            os.close(config_fd)
    finally:
        os.close(directory_fd)


def render_publish(
    runtime_path,
    directory_id,
    current_name,
    current_id,
    source_path,
    replacement,
):
    ipaddress.ip_address(replacement)
    validate_config_name(current_name)
    directory_fd, _ = open_runtime(runtime_path, directory_id)
    temporary_fd = None
    source_fd = None
    temporary_name = None
    temporary_id = None
    generation_name = None
    published = False
    try:
        validate_named_file(directory_fd, current_name, current_id)
        temporary_name, temporary_fd = create_temporary(
            directory_fd, ".prometheus.resolved."
        )
        temporary_stat = os.fstat(temporary_fd)
        validate_file_stat(temporary_stat)
        temporary_id = identity(temporary_stat)
        validate_named_file(directory_fd, temporary_name, temporary_id)

        source_fd = os.open(source_path, os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            raise RuntimeError("Prometheus render source is not a regular file")
        render = subprocess.run(
            ["sed", f"s|argus-exporter:9100|{replacement}:9100|g"],
            stdin=source_fd,
            stdout=temporary_fd,
            check=False,
        )
        if render.returncode != 0:
            raise RuntimeError("Prometheus runtime config rendering failed")
        os.fsync(temporary_fd)
        os.lseek(temporary_fd, 0, os.SEEK_SET)
        validate_file_stat(os.fstat(temporary_fd), temporary_id)
        validate_named_file(directory_fd, temporary_name, temporary_id)
        rendered = read_all(temporary_fd)
        if not rendered:
            raise RuntimeError("rendered Prometheus config is empty")
        validate_file_stat(os.fstat(temporary_fd), temporary_id)
        validate_named_file(directory_fd, temporary_name, temporary_id)
        validate_named_file(directory_fd, current_name, current_id)
        revalidate_runtime(runtime_path, directory_fd, directory_id)
        os.lseek(temporary_fd, 0, os.SEEK_SET)
        if read_all(temporary_fd) != rendered:
            raise RuntimeError("rendered Prometheus config readback differs")

        generation_name = f"prometheus.resolved.{secrets.token_hex(12)}.yml"
        os.link(
            temporary_name,
            generation_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        published = True
        validate_named_file(directory_fd, temporary_name, temporary_id, links=2)
        validate_named_file(directory_fd, generation_name, temporary_id, links=2)
        unlink_bound(directory_fd, temporary_name, temporary_id)
        temporary_name = None
        validate_named_file(directory_fd, generation_name, temporary_id)
        validate_named_file(directory_fd, current_name, current_id)
        revalidate_runtime(runtime_path, directory_fd, directory_id)
        os.fsync(directory_fd)
        print(generation_name, temporary_id)
    except Exception:
        if published and generation_name is not None and temporary_id is not None:
            try:
                unlink_bound(directory_fd, generation_name, temporary_id)
            except (FileNotFoundError, RuntimeError, OSError):
                pass
        raise
    finally:
        if temporary_name is not None and temporary_id is not None:
            try:
                unlink_bound(directory_fd, temporary_name, temporary_id)
            except (FileNotFoundError, RuntimeError, OSError):
                pass
        if source_fd is not None:
            os.close(source_fd)
        if temporary_fd is not None:
            os.close(temporary_fd)
        os.close(directory_fd)


try:
    action = sys.argv[1]
    if action == "prepare" and len(sys.argv) == 4:
        prepare(sys.argv[2], sys.argv[3])
    elif action == "adopt" and len(sys.argv) == 3:
        adopt(sys.argv[2])
    elif action == "verify" and len(sys.argv) == 6:
        verify(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif action == "render-publish" and len(sys.argv) == 8:
        render_publish(
            sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
        )
    else:
        raise RuntimeError("invalid runtime config transaction")
except (OSError, RuntimeError) as error:
    print(f"Runtime config transaction rejected: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

prepare_runtime_config() {
  local receipt runtime_candidate

  if [ -n "${ODYSSEUS_E2E_RUNTIME_DIR:-}" ]; then
    runtime_candidate="$ODYSSEUS_E2E_RUNTIME_DIR"
  else
    runtime_candidate="$(mktemp -d \
        "${TMPDIR:-/tmp}/homeric-intelligence-e2e.XXXXXX")"
  fi
  if ! RUNTIME_DIRECTORY="$(python3 -c \
      'import os,sys; print(os.path.abspath(sys.argv[1]))' \
      "$runtime_candidate")" \
      || [ -L "$RUNTIME_DIRECTORY" ] || [ ! -d "$RUNTIME_DIRECTORY" ]; then
    echo "E2E runtime path is not an existing direct directory: $runtime_candidate" >&2
    return 1
  fi

  PROMETHEUS_CONFIG_NAME="prometheus.runtime.yml"
  PROMETHEUS_CONFIG="$RUNTIME_DIRECTORY/$PROMETHEUS_CONFIG_NAME"
  if ! receipt="$(runtime_config_transaction prepare \
      "$RUNTIME_DIRECTORY" "$ODYSSEUS_ROOT/e2e/prometheus.yml")"; then
    echo "Cannot publish E2E runtime config: $PROMETHEUS_CONFIG" >&2
    return 1
  fi
  read -r RUNTIME_DIRECTORY_ID PROMETHEUS_CONFIG_ID <<<"$receipt"
  if [ -z "$RUNTIME_DIRECTORY_ID" ] || [ -z "$PROMETHEUS_CONFIG_ID" ]; then
    echo "Runtime config transaction returned an incomplete receipt" >&2
    return 1
  fi

  export PROJECT_ROOT HERMES_DIR ARGUS_DIR MYRMIDONS_DIR PODMAN_SOCK PROMETHEUS_CONFIG
}

validate_container_record() {
  local expected_name="$1" expected_service="$2" expected_image="$3"
  local expected_image_volumes="$4" expected_image_config="$5"
  local expected_network="$6" prometheus_source="$7" required_id="$8"
  local contract_mode="$9" nats_ip="${10}" agamemnon_ip="${11}"
  local nestor_ip="${12}"
  python3 -c '
import json
import os
import re
import stat
import sys


def reject(message):
    print(f"Container ownership rejected: {message}", file=sys.stderr)
    raise SystemExit(1)


def normalized_id(value, kind):
    if not isinstance(value, str):
        reject(f"{kind} ID is absent")
    normalized = value.removeprefix("sha256:")
    if re.fullmatch(r"[0-9a-f]{64}", normalized) is None:
        reject(f"{kind} ID is not immutable")
    return normalized


def readonly_bind(mount, source, destination):
    return (
        isinstance(mount, dict)
        and mount.get("Type") == "bind"
        and mount.get("Source") == source
        and mount.get("Destination") == destination
        and (
            mount.get("RW") is False
            or mount.get("ReadOnly") is True
            or "ro" in mount.get("Options", [])
        )
    )


def validate_existing_runtime_source(source):
    if not isinstance(source, str) or source != os.path.abspath(source):
        reject("existing Prometheus source is not an absolute path")
    parent, name = os.path.split(source)
    if not parent or not name:
        reject("existing Prometheus source is not a direct file")
    try:
        parent_before = os.lstat(parent)
        if not stat.S_ISDIR(parent_before.st_mode):
            reject("existing Prometheus parent is not a direct directory")
        if parent_before.st_uid != os.geteuid() or stat.S_IMODE(parent_before.st_mode) != 0o700:
            reject("existing Prometheus parent is not owner-private")
        for flag in ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC"):
            if not hasattr(os, flag):
                reject(f"platform does not provide {flag}")
        directory_fd = os.open(
            parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        try:
            parent_open = os.fstat(directory_fd)
            if (parent_open.st_dev, parent_open.st_ino) != (
                parent_before.st_dev,
                parent_before.st_ino,
            ):
                reject("existing Prometheus parent changed while opening")
            file_fd = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory_fd,
            )
            try:
                opened = os.fstat(file_fd)
                named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
                    reject("existing Prometheus source changed while opening")
                if not stat.S_ISREG(opened.st_mode):
                    reject("existing Prometheus source is not regular")
                if opened.st_uid != os.geteuid():
                    reject("existing Prometheus source has a foreign owner")
                if stat.S_IMODE(opened.st_mode) != 0o644 or opened.st_nlink != 1:
                    reject("existing Prometheus source is not read-only bind compatible and singly linked")
            finally:
                os.close(file_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        reject(f"existing Prometheus source is unavailable: {error}")


(expected_name, expected_service, expected_image, expected_image_volumes,
 expected_image_config, expected_network, prometheus_source, required_id,
 contract_mode, nats_ip, agamemnon_ip, nestor_ip, project_root,
 argus_root, grafana_password) = sys.argv[1:]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError) as error:
    reject(f"inspect output is not JSON: {error}")
if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
    reject("inspect output must contain exactly one container")
record = payload[0]

container_id = normalized_id(record.get("Id"), "container")
if required_id and container_id != normalized_id(required_id, "required container"):
    reject("reserved name now resolves to a different container")
if str(record.get("Name", "")).lstrip("/") != expected_name:
    reject("actual container name differs from the reserved name")
if normalized_id(record.get("Image"), "image") != normalized_id(expected_image, "expected image"):
    reject("container image differs from the bound image")

labels = (record.get("Config") or {}).get("Labels") or {}
valid_label_families = 0
for prefix in ("com.docker.compose", "io.podman.compose"):
    project_label = labels.get(f"{prefix}.project")
    service_label = labels.get(f"{prefix}.service")
    if project_label is None and service_label is None:
        continue
    if project_label != "odysseus":
        reject(f"{prefix} project ownership label differs")
    if service_label != expected_service:
        reject(f"{prefix} service ownership label differs")
    valid_label_families += 1
if valid_label_families == 0:
    reject("container has no recognized Compose ownership labels")

networks = (record.get("NetworkSettings") or {}).get("Networks")
if not isinstance(networks, dict) or set(networks) != {"odysseus_homeric-mesh"}:
    reject("container network membership differs")
network = networks["odysseus_homeric-mesh"]
if not isinstance(network, dict):
    reject("container network attachment is malformed")
normalized_id(expected_network, "expected network")

try:
    image_config = json.loads(expected_image_config)
except json.JSONDecodeError as error:
    reject(f"bound image config is malformed: {error}")
if not isinstance(image_config, dict):
    reject("bound image config is not an object")
config = record.get("Config")
host_config = record.get("HostConfig")
network_settings = record.get("NetworkSettings")
if not isinstance(config, dict) or not isinstance(host_config, dict) \
        or not isinstance(network_settings, dict):
    reject("container runtime config is absent")


def env_map(value, kind):
    if value is None:
        return {}
    if not isinstance(value, list):
        reject(f"{kind} environment is not a list")
    result = {}
    for item in value:
        if not isinstance(item, str) or "=" not in item:
            reject(f"{kind} environment contains a malformed entry")
        key, entry_value = item.split("=", 1)
        if not key or key in result:
            reject(f"{kind} environment contains a duplicate or empty key")
        result[key] = entry_value
    return result


def normalized_argv(value, kind):
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        reject(f"{kind} is not a string array")
    return value


def compose_environment():
    return {
        "agamemnon": {"NATS_URL": "nats://nats:4222"},
        "nestor": {"NATS_URL": "nats://nats:4222"},
        "hermes": {
            "NATS_URL": "nats://nats:4222",
            "HERMES_PORT": "8085",
        },
        "grafana": {
            "GF_AUTH_ANONYMOUS_ENABLED": "false",
            "GF_SECURITY_ADMIN_PASSWORD": grafana_password,
            "GF_SECURITY_ALLOW_EMBEDDING": "true",
            "GF_ANALYTICS_REPORTING_ENABLED": "false",
            "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
            "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES": "false",
        },
        "argus-exporter": {
            "AGAMEMNON_URL": "http://agamemnon:8080",
            "NESTOR_URL": "http://nestor:8081",
            "NATS_URL": "http://nats:8222",
        },
        "hello-myrmidon": {
            "NATS_URL": "nats://nats:4222",
            "AGAMEMNON_URL": "http://agamemnon:8080",
        },
    }.get(expected_service, {})


def resolved_environment():
    required = {
        "agamemnon": (nats_ip,),
        "hermes": (nats_ip,),
        "argus-exporter": (agamemnon_ip, nestor_ip, nats_ip),
        "hello-myrmidon": (nats_ip, agamemnon_ip),
    }.get(expected_service, ())
    if any(not value for value in required):
        return None
    resolved = {
        "agamemnon": {"NATS_URL": f"nats://{nats_ip}:4222"},
        "hermes": {
            "NATS_URL": f"nats://{nats_ip}:4222",
            "HERMES_PORT": "8085",
        },
        "argus-exporter": {
            "AGAMEMNON_URL": f"http://{agamemnon_ip}:8080",
            "NESTOR_URL": f"http://{nestor_ip}:8081",
            "NATS_URL": f"http://{nats_ip}:8222",
        },
        "hello-myrmidon": {
            "NATS_URL": f"nats://{nats_ip}:4222",
            "AGAMEMNON_URL": f"http://{agamemnon_ip}:8080",
        },
    }
    return resolved.get(expected_service, compose_environment())


base_environment = env_map(image_config.get("Env"), "image")
actual_environment = env_map(config.get("Env"), "container")


def podman_environments():
    runtime = {}
    if "PATH" not in base_environment:
        runtime["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if "container" not in base_environment:
        runtime["container"] = "podman"
    if "HOME" not in base_environment:
        image_user = image_config.get("User", "")
        runtime_home = {
            ("prometheus", "nobody"): "/home",
            ("loki", "10001"): "/home/loki",
            ("grafana", "472"): "/home/grafana",
        }.get((expected_service, image_user))
        if image_user in ("", "0", "root", "0:0", "root:root"):
            runtime_home = "/root"
        if runtime_home is None:
            reject("bound image has no deterministic HOME for its non-root user")
        runtime["HOME"] = runtime_home

    hostname = config.get("Hostname")
    if not isinstance(hostname, str) or hostname not in {
            container_id[:12], expected_name}:
        reject("container hostname differs from the Podman runtime identity")
    runtime["HOSTNAME"] = hostname

    for key in (
            "http_proxy", "https_proxy", "ftp_proxy", "no_proxy",
            "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "NO_PROXY"):
        if key not in actual_environment or key in base_environment:
            continue
        ambient = os.environ.get(key)
        if ambient is None or actual_environment[key] != ambient:
            reject(f"container {key} differs from the invoking Podman environment")
        runtime[key] = ambient

    options = [runtime]
    if "TERM" not in base_environment:
        with_term = dict(runtime)
        with_term["TERM"] = "xterm"
        options.append(with_term)
    return options


runtime_environments = podman_environments()
environment_options = []
if contract_mode in ("compose", "either"):
    environment_options.append(compose_environment())
if contract_mode in ("resolved", "either", "final"):
    if contract_mode == "final" and expected_service not in {
            "agamemnon", "hermes", "argus-exporter", "hello-myrmidon"}:
        environment_options.append(compose_environment())
    else:
        resolved = resolved_environment()
        if resolved is not None:
            environment_options.append(resolved)
if not environment_options:
    reject("runtime contract mode cannot resolve the service environment")
expected_environments = []
for overrides in environment_options:
    for runtime_environment in runtime_environments:
        candidate = dict(base_environment)
        candidate.update(runtime_environment)
        candidate.update(overrides)
        if candidate not in expected_environments:
            expected_environments.append(candidate)
if actual_environment not in expected_environments:
    reject("container environment differs from the selected runtime contract")

command_overrides = {
    "nats": ["-js", "-m", "8222"],
    "prometheus": [
        "--config.file=/etc/prometheus/prometheus.yml",
        "--web.enable-lifecycle",
    ],
    "loki": ["-config.file=/etc/loki/local-config.yaml"],
}
expected_command = command_overrides.get(
    expected_service, normalized_argv(image_config.get("Cmd"), "image command")
)
if normalized_argv(config.get("Cmd"), "container command") != expected_command:
    reject("container command differs from the selected runtime contract")
if normalized_argv(config.get("Entrypoint"), "container entrypoint") != \
        normalized_argv(image_config.get("Entrypoint"), "image entrypoint"):
    reject("container entrypoint differs from the bound image")

published_ports = {
    "nats": {"4222/tcp": "4222", "8222/tcp": "8222"},
    "agamemnon": {"8080/tcp": "8080"},
    "nestor": {"8081/tcp": "8081"},
    "hermes": {"8085/tcp": "8085"},
    "prometheus": {"9090/tcp": "9090"},
    "loki": {"3100/tcp": "3100"},
    "grafana": {"3000/tcp": "3001"},
    "argus-exporter": {"9100/tcp": "9100"},
    "hello-myrmidon": {},
}[expected_service]


def normalized_bound_ports(value, kind):
    if value in (None, {}):
        return {}
    if not isinstance(value, dict):
        reject(f"{kind} port bindings are not an object")
    normalized = {}
    for container_port, bindings in value.items():
        if not isinstance(container_port, str) or not isinstance(bindings, list) \
                or len(bindings) != 1 or not isinstance(bindings[0], dict):
            reject(f"{kind} port binding is malformed")
        host_ip = bindings[0].get("HostIp", "")
        host_port = bindings[0].get("HostPort")
        if host_ip not in ("", "0.0.0.0", "::") or not isinstance(host_port, str):
            reject(f"{kind} port binding has an unexpected host endpoint")
        normalized[container_port] = host_port
    return normalized


if normalized_bound_ports(host_config.get("PortBindings"), "host") != published_ports:
    reject("host port bindings differ from the Compose contract")
image_exposed = image_config.get("ExposedPorts")
if image_exposed is None:
    image_exposed = {}
if not isinstance(image_exposed, dict):
    reject("bound image exposed-port contract is malformed")
expected_exposed = set(image_exposed) | set(published_ports)
actual_exposed = config.get("ExposedPorts")
if actual_exposed is None:
    actual_exposed = {}
if not isinstance(actual_exposed, dict) or set(actual_exposed) != expected_exposed:
    reject("container exposed ports differ from the image and Compose contract")
network_ports = network_settings.get("Ports")
if network_ports is None:
    network_ports = {}
if not isinstance(network_ports, dict) or set(network_ports) != expected_exposed:
    reject("network exposed-port inventory differs from the selected contract")
for container_port, bindings in network_ports.items():
    if container_port in published_ports:
        normalized = normalized_bound_ports(
            {container_port: bindings}, "network"
        )
        if normalized != {container_port: published_ports[container_port]}:
            reject("network published-port binding differs from the Compose contract")
    elif bindings not in (None, []):
        reject("image-exposed port unexpectedly has a host binding")

resources = {
    "nats": (1_000_000_000, 256, 512 * 1024 * 1024, 128 * 1024 * 1024),
    "agamemnon": (2_000_000_000, 256, 1024 * 1024 * 1024, 128 * 1024 * 1024),
    "nestor": (2_000_000_000, 256, 1024 * 1024 * 1024, 128 * 1024 * 1024),
    "hermes": (1_000_000_000, 256, 512 * 1024 * 1024, 128 * 1024 * 1024),
    "prometheus": (2_000_000_000, 512, 2 * 1024 * 1024 * 1024, 256 * 1024 * 1024),
    "loki": (2_000_000_000, 512, 2 * 1024 * 1024 * 1024, 256 * 1024 * 1024),
    "grafana": (1_000_000_000, 256, 512 * 1024 * 1024, 128 * 1024 * 1024),
    "argus-exporter": (1_000_000_000, 256, 512 * 1024 * 1024, 128 * 1024 * 1024),
    "hello-myrmidon": (2_000_000_000, 256, 1024 * 1024 * 1024, 128 * 1024 * 1024),
}
expected_nano_cpus, direct_cpu_shares, expected_memory, expected_reservation = \
    resources[expected_service]


def contract_values(compose_value, direct_value):
    if contract_mode == "compose":
        return {compose_value}
    if contract_mode == "resolved":
        return {direct_value}
    if contract_mode == "either":
        return {compose_value, direct_value}
    if contract_mode == "final":
        direct_services = {
            "agamemnon", "hermes", "prometheus",
            "argus-exporter", "hello-myrmidon",
        }
        return {direct_value if expected_service in direct_services else compose_value}
    reject("runtime contract mode is invalid")


actual_nano_cpus = host_config.get("NanoCpus", 0)
if not isinstance(actual_nano_cpus, int):
    reject("container CPU limit is malformed")
if actual_nano_cpus == 0:
    period = host_config.get("CpuPeriod", 0)
    quota = host_config.get("CpuQuota", 0)
    if not isinstance(period, int) or not isinstance(quota, int) or period <= 0:
        reject("container CPU limit is absent")
    actual_nano_cpus = quota * 1_000_000_000 // period
if actual_nano_cpus != expected_nano_cpus:
    reject("container CPU limit differs from the Compose contract")
if host_config.get("CpuShares") not in contract_values(0, direct_cpu_shares):
    reject("container CPU reservation differs from the Compose contract")
if host_config.get("Memory") != expected_memory \
        or host_config.get("MemoryReservation") != expected_reservation:
    reject("container memory resources differ from the Compose contract")

restart_policy = host_config.get("RestartPolicy")
if not isinstance(restart_policy, dict):
    reject("container restart policy is absent")
restart_name = restart_policy.get("Name", "")
restart_count = restart_policy.get("MaximumRetryCount", 0)
if expected_service == "hello-myrmidon":
    valid_restart = (
        restart_name == "on-failure"
        and restart_count in contract_values(0, 5)
    )
else:
    valid_restart = restart_name in ("", "no") and restart_count == 0
if not valid_restart:
    reject("container restart policy differs from the Compose contract")

if config.get("StartupHealthCheck") is not None:
    reject("container has an unexpected startup health check")
if config.get("HealthcheckOnFailureAction", "none") != "none":
    reject("container health failure action differs from the Podman default")
if config.get("HealthLogDestination", "local") != "local" \
        or config.get("HealthcheckMaxLogCount", 5) != 5 \
        or config.get("HealthcheckMaxLogSize", 500) != 500:
    reject("container health log controls differ from the bounded defaults")

healthchecks = {
    "nats": (
        ["CMD", "sh", "-c",
         "wget -q --spider http://localhost:8222/healthz 2>/dev/null || exit 1"],
        5_000_000_000,
    ),
    "agamemnon": (
        ["CMD", "sh", "-c",
         "wget -qO- http://localhost:8080/v1/health 2>/dev/null || exit 1"],
        10_000_000_000,
    ),
    "nestor": (
        ["CMD", "sh", "-c",
         "wget -qO- http://localhost:8081/v1/health 2>/dev/null || exit 1"],
        10_000_000_000,
    ),
    "hermes": (
        ["CMD", "sh", "-c",
         "python3 -c \"import urllib.request; urllib.request.urlopen(\x27http://localhost:8085/health\x27)\" 2>/dev/null || exit 1"],
        10_000_000_000,
    ),
}
if expected_service in healthchecks:
    expected_test, expected_start_period = healthchecks[expected_service]
    actual_health = config.get("Healthcheck") or config.get("HealthCheck")
    if not isinstance(actual_health, dict):
        reject("container health check is absent")
    actual_test = actual_health.get("Test")
    command_text = expected_test[-1]
    if actual_test not in (expected_test, ["CMD-SHELL", command_text]):
        reject("container health command differs from the Compose contract")
    if actual_health.get("Interval") != 5_000_000_000 \
            or actual_health.get("Timeout") != 3_000_000_000 \
            or actual_health.get("Retries") != 10 \
            or actual_health.get("StartPeriod") != expected_start_period:
        reject("container health timing differs from the Compose contract")
else:
    expected_health = image_config.get("Healthcheck", image_config.get("HealthCheck"))
    actual_health = config.get("Healthcheck", config.get("HealthCheck"))
    if actual_health != expected_health:
        reject("container health check differs from the bound image")

mounts = record.get("Mounts")
if not isinstance(mounts, list):
    reject("container mount inventory is absent")
try:
    declared_volumes = json.loads(expected_image_volumes)
except json.JSONDecodeError as error:
    reject(f"bound image volume declaration is malformed: {error}")
if not isinstance(declared_volumes, dict) or not all(
    isinstance(destination, str) and destination.startswith("/")
    for destination in declared_volumes
):
    reject("bound image volume declaration is not an absolute-path map")

required_binds = {}
if expected_service == "prometheus":
    config_mounts = [mount for mount in mounts if isinstance(mount, dict)
                     and mount.get("Destination") == "/etc/prometheus/prometheus.yml"]
    if len(config_mounts) != 1:
        reject("Prometheus config mount inventory differs")
    source = config_mounts[0].get("Source")
    if prometheus_source == "__existing__":
        validate_existing_runtime_source(source)
        expected_source = source
    else:
        expected_source = prometheus_source
    required_binds["/etc/prometheus/prometheus.yml"] = expected_source
elif expected_service == "grafana":
    required_binds = {
        "/etc/grafana/provisioning": os.path.join(
            project_root, "e2e/grafana/provisioning"
        ),
        "/var/lib/grafana/dashboards": os.path.join(argus_root, "dashboards"),
    }

expected_destinations = set(required_binds) | set(declared_volumes)
if len(mounts) != len(expected_destinations):
    reject("container mount inventory differs from its image and service contract")
seen_destinations = set()
for mount in mounts:
    if not isinstance(mount, dict):
        reject("container mount record is malformed")
    destination = mount.get("Destination")
    if destination in seen_destinations or destination not in expected_destinations:
        reject(f"container has an unexpected or duplicate mount: {destination!r}")
    seen_destinations.add(destination)
    if destination in required_binds:
        if not readonly_bind(mount, required_binds[destination], destination):
            reject(f"required read-only bind differs: {destination}")
        continue
    volume_name = mount.get("Name")
    volume_source = mount.get("Source")
    if mount.get("Type") != "volume" \
            or not isinstance(volume_name, str) \
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", volume_name) is None \
            or not isinstance(volume_source, str) \
            or volume_source != os.path.abspath(volume_source) \
            or mount.get("RW") is not True:
        reject(f"image-declared storage mount differs: {destination}")
if seen_destinations != expected_destinations:
    reject("container mount destinations are incomplete")

print(container_id)
' "$expected_name" "$expected_service" "$expected_image" \
    "$expected_image_volumes" "$expected_image_config" "$expected_network" \
    "$prometheus_source" "$required_id" "$contract_mode" "$nats_ip" \
    "$agamemnon_ip" "$nestor_ip" "$PROJECT_ROOT" "$ARGUS_DIR" \
    "${GF_E2E_ADMIN_PASSWORD:-e2e-not-for-prod}"
}

immutable_asset_id() {
  [[ "$1" =~ ^(sha256:)?[0-9a-f]{64}$ ]]
}

network_contains_container() {
  local container_id="$1" container_name="$2"
  podman network inspect "$STACK_NETWORK_ID" | python3 -c '
import json
import re
import sys


def normalized(value):
    if not isinstance(value, str):
        raise ValueError("missing immutable ID")
    value = value.removeprefix("sha256:")
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("malformed immutable ID")
    return value


try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, list) or len(payload) != 1:
        raise ValueError("network inspect must return one object")
    network = payload[0]
    if normalized(network.get("id", network.get("ID"))) != normalized(sys.argv[3]):
        raise ValueError("network ID changed")
    if network.get("name", network.get("Name")) != sys.argv[4]:
        raise ValueError("network name changed")
    members = network.get("containers", network.get("Containers"))
    if not isinstance(members, dict):
        raise ValueError("network member inventory is absent")
    member = members.get(normalized(sys.argv[1]))
    if not isinstance(member, dict):
        raise ValueError("bound container is absent from the network")
    if member.get("name", member.get("Name")) != sys.argv[2]:
        raise ValueError("network member name differs")
except (json.JSONDecodeError, ValueError) as error:
    print(f"Network membership rejected: {error}", file=sys.stderr)
    raise SystemExit(1)
' "$container_id" "$container_name" "$STACK_NETWORK_ID" "$STACK_NETWORK"
}

resolve_stack_network() {
  if ! STACK_NETWORK_ID="$(podman network inspect --format '{{.ID}}' "$STACK_NETWORK")" \
      || ! immutable_asset_id "$STACK_NETWORK_ID"; then
    echo "Cannot bind the immutable $STACK_NETWORK network" >&2
    return 1
  fi
}

resolve_stack_image() {
  local image_index="$1" image_id image_volumes image_config
  if ! image_id="$(podman image inspect --format '{{.Id}}' \
      "${REQUIRED_IMAGE_REFS[$image_index]}")" \
      || ! immutable_asset_id "$image_id"; then
    echo "Cannot bind image ${REQUIRED_IMAGE_REFS[$image_index]}" >&2
    return 1
  fi
  if ! image_volumes="$(podman image inspect \
      --format '{{json .Config.Volumes}}' \
      "${REQUIRED_IMAGE_REFS[$image_index]}")" \
      || ! image_volumes="$(printf '%s\n' "$image_volumes" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
if value is None:
    value = {}
if not isinstance(value, dict) or not all(
        isinstance(path, str) and path.startswith("/") for path in value):
    raise SystemExit(1)
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
')"; then
    echo "Cannot bind volume contract for ${REQUIRED_IMAGE_REFS[$image_index]}" >&2
    return 1
  fi
  if ! image_config="$(podman image inspect \
      --format '{{json .Config}}' \
      "${REQUIRED_IMAGE_REFS[$image_index]}")" \
      || ! image_config="$(printf '%s\n' "$image_config" | python3 -c '
import json
import sys

value = json.load(sys.stdin)
if not isinstance(value, dict):
    raise SystemExit(1)
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
')"; then
    echo "Cannot bind runtime config for ${REQUIRED_IMAGE_REFS[$image_index]}" >&2
    return 1
  fi
  EXPECTED_IMAGE_IDS[image_index]="$image_id"
  EXPECTED_IMAGE_VOLUMES[image_index]="$image_volumes"
  EXPECTED_IMAGE_CONFIGS[image_index]="$image_config"
}

resolve_stack_assets() {
  local image_index bound_network_id="${STACK_NETWORK_ID:-}"
  resolve_stack_network || return 1
  if [ -n "$bound_network_id" ] \
      && [ "${STACK_NETWORK_ID#sha256:}" != "${bound_network_id#sha256:}" ]; then
    echo "Selected stack network identity changed during Compose" >&2
    return 1
  fi
  for ((image_index = 0; image_index < ${#REQUIRED_IMAGE_REFS[@]}; image_index++)); do
    if [ -z "${EXPECTED_IMAGE_IDS[$image_index]:-}" ]; then
      resolve_stack_image "$image_index" || return 1
    fi
  done
}

bind_one_container() {
  local container_index="$1" prometheus_source="$2" required_id="$3"
  local inspect_target="${4:-${REQUIRED_CONTAINERS[$container_index]}}"
  local contract_mode="${5:-either}" record bound_id
  if ! record="$(podman inspect "$inspect_target")"; then
    echo "Cannot inspect reserved container ${REQUIRED_CONTAINERS[$container_index]}" >&2
    return 1
  fi
  if ! bound_id="$(printf '%s\n' "$record" | validate_container_record \
      "${REQUIRED_CONTAINERS[$container_index]}" \
      "${REQUIRED_SERVICES[$container_index]}" \
      "${EXPECTED_IMAGE_IDS[$container_index]}" \
      "${EXPECTED_IMAGE_VOLUMES[$container_index]}" \
      "${EXPECTED_IMAGE_CONFIGS[$container_index]}" "$STACK_NETWORK_ID" \
      "$prometheus_source" "$required_id" "$contract_mode" "$NATS_IP" \
      "$AGAMEMNON_IP" "$NESTOR_IP")"; then
    echo "Reserved container ${REQUIRED_CONTAINERS[$container_index]} is foreign or stale" >&2
    return 1
  fi
  if ! network_contains_container "$bound_id" \
      "${REQUIRED_CONTAINERS[$container_index]}"; then
    echo "Reserved container ${REQUIRED_CONTAINERS[$container_index]} is not on the bound network" >&2
    return 1
  fi
  printf '%s\n' "$bound_id"
}

container_ip() {
  podman inspect "$1" 2>/dev/null | python3 -c '
import ipaddress
import json
import sys

payload = json.load(sys.stdin)
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit(1)
networks = (payload[0].get("NetworkSettings") or {}).get("Networks")
if not isinstance(networks, dict) or set(networks) != {"odysseus_homeric-mesh"}:
    raise SystemExit(1)
address = networks["odysseus_homeric-mesh"].get("IPAddress")
ipaddress.ip_address(address)
print(address)
'
}

record_bound_service_ip() {
  local container_index="$1" bound_id="$2" address
  case "${REQUIRED_SERVICES[$container_index]}" in
    nats)
      address="$(container_ip "$bound_id")" || return 1
      NATS_IP="$address"
      ;;
    agamemnon)
      address="$(container_ip "$bound_id")" || return 1
      AGAMEMNON_IP="$address"
      ;;
    nestor)
      address="$(container_ip "$bound_id")" || return 1
      NESTOR_IP="$address"
      ;;
  esac
}

bind_existing_stack() {
  local container_index exists_status bound_id
  local any_existing=false complete=true network_resolved=false
  BOUND_CONTAINER_IDS=()
  EXPECTED_IMAGE_IDS=()
  EXPECTED_IMAGE_VOLUMES=()
  EXPECTED_IMAGE_CONFIGS=()
  NATS_IP=""
  AGAMEMNON_IP=""
  NESTOR_IP=""
  for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
    if podman container exists "${REQUIRED_CONTAINERS[$container_index]}"; then
      any_existing=true
      if [ "$network_resolved" = false ]; then
        resolve_stack_network || return 2
        network_resolved=true
      fi
      resolve_stack_image "$container_index" || return 2
      if ! bound_id="$(bind_one_container "$container_index" __existing__ "" \
          "${REQUIRED_CONTAINERS[$container_index]}" either)"; then
        return 2
      fi
      BOUND_CONTAINER_IDS[container_index]="$bound_id"
      record_bound_service_ip "$container_index" "$bound_id" || return 2
    else
      exists_status=$?
      if [ "$exists_status" -ne 1 ]; then
        echo "Cannot determine whether ${REQUIRED_CONTAINERS[$container_index]} exists" >&2
        return 2
      fi
      complete=false
      BOUND_CONTAINER_IDS[container_index]=""
    fi
  done
  [ "$any_existing" = true ] || return 1
  [ "$complete" = true ] || return 1
}

adopt_bound_runtime_config() {
  local record receipt
  if ! record="$(podman inspect "${BOUND_CONTAINER_IDS[4]}")" \
      || ! PROMETHEUS_CONFIG="$(printf '%s\n' "$record" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit(1)
mounts = payload[0].get("Mounts")
if not isinstance(mounts, list):
    raise SystemExit(1)
matches = [mount for mount in mounts if isinstance(mount, dict)
           and mount.get("Destination") == "/etc/prometheus/prometheus.yml"]
if len(matches) != 1:
    raise SystemExit(1)
source = matches[0].get("Source")
if not isinstance(source, str) or "\n" in source:
    raise SystemExit(1)
print(source)
')"; then
    echo "Cannot recover the bound Prometheus runtime source" >&2
    return 1
  fi
  PROMETHEUS_CONFIG_NAME="${PROMETHEUS_CONFIG##*/}"
  RUNTIME_DIRECTORY="${PROMETHEUS_CONFIG%/*}"
  if [ "$RUNTIME_DIRECTORY" = "$PROMETHEUS_CONFIG" ] \
      || [ -z "$PROMETHEUS_CONFIG_NAME" ] \
      || ! receipt="$(runtime_config_transaction adopt "$PROMETHEUS_CONFIG")"; then
    echo "Cannot adopt the existing Prometheus runtime source" >&2
    return 1
  fi
  read -r RUNTIME_DIRECTORY_ID PROMETHEUS_CONFIG_ID <<<"$receipt"
  if [ -z "$RUNTIME_DIRECTORY_ID" ] || [ -z "$PROMETHEUS_CONFIG_ID" ]; then
    echo "Runtime adoption returned an incomplete receipt" >&2
    return 1
  fi
  export PROJECT_ROOT HERMES_DIR ARGUS_DIR MYRMIDONS_DIR PODMAN_SOCK PROMETHEUS_CONFIG
}

bind_complete_stack() {
  local prometheus_source="$1" container_index bound_id required_id contract_mode
  resolve_stack_assets || return 1
  for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
    required_id="${PREEXISTING_CONTAINER_IDS[$container_index]:-}"
    contract_mode=compose
    [ -z "$required_id" ] || contract_mode=either
    if ! podman container exists "${REQUIRED_CONTAINERS[$container_index]}" \
        || ! bound_id="$(bind_one_container "$container_index" \
            "$prometheus_source" "$required_id" \
            "${REQUIRED_CONTAINERS[$container_index]}" "$contract_mode")"; then
      echo "Compose did not produce the exact selected container topology" >&2
      return 1
    fi
    BOUND_CONTAINER_IDS[container_index]="$bound_id"
    record_bound_service_ip "$container_index" "$bound_id" || return 1
  done
}

revalidate_bound_stack() {
  local prometheus_source="$1" contract_mode="${2:-either}"
  local container_index rebound_id
  for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
    if ! rebound_id="$(bind_one_container "$container_index" "$prometheus_source" \
        "${BOUND_CONTAINER_IDS[$container_index]}" \
        "${REQUIRED_CONTAINERS[$container_index]}" "$contract_mode")" \
        || [ "$rebound_id" != "${BOUND_CONTAINER_IDS[$container_index]}" ]; then
      echo "Reserved container binding changed: ${REQUIRED_CONTAINERS[$container_index]}" >&2
      return 1
    fi
    record_bound_service_ip "$container_index" "$rebound_id" || return 1
  done
}

revalidate_existing_bindings() {
  local container_index rebound_id
  for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
    [ -n "${BOUND_CONTAINER_IDS[$container_index]:-}" ] || continue
    if ! rebound_id="$(bind_one_container "$container_index" __existing__ \
        "${BOUND_CONTAINER_IDS[$container_index]}" \
        "${REQUIRED_CONTAINERS[$container_index]}" either)" \
        || [ "$rebound_id" != "${BOUND_CONTAINER_IDS[$container_index]}" ]; then
      echo "Existing container binding changed before Compose: ${REQUIRED_CONTAINERS[$container_index]}" >&2
      return 1
    fi
    record_bound_service_ip "$container_index" "$rebound_id" || return 1
  done
}

capture_prometheus_volume() {
  local container_target="$1" expected_container_id="$2" expected_config="$3"
  local record mount_receipt volume_name volume_record verified_receipt
  if ! record="$(podman inspect "$container_target")" \
      || ! mount_receipt="$(printf '%s\n' "$record" | python3 -c '
import json
import os
import re
import sys

payload = json.load(sys.stdin)
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit(1)
record = payload[0]
actual_id = str(record.get("Id", "")).removeprefix("sha256:")
expected_id = sys.argv[1].removeprefix("sha256:")
if actual_id != expected_id or re.fullmatch(r"[0-9a-f]{64}", actual_id) is None:
    raise SystemExit(1)
if str(record.get("Name", "")).lstrip("/") != "odysseus-prometheus-1":
    raise SystemExit(1)
mounts = record.get("Mounts")
if not isinstance(mounts, list):
    raise SystemExit(1)
configs = [mount for mount in mounts if isinstance(mount, dict)
           and mount.get("Destination") == "/etc/prometheus/prometheus.yml"]
volumes = [mount for mount in mounts if isinstance(mount, dict)
           and mount.get("Destination") == "/prometheus"]
if len(configs) != 1 or configs[0].get("Source") != sys.argv[2] \
        or len(volumes) != 1:
    raise SystemExit(1)
volume = volumes[0]
name = volume.get("Name")
source = volume.get("Source")
if volume.get("Type") != "volume" or volume.get("RW") is not True \
        or not isinstance(name, str) \
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name) is None \
        or not isinstance(source, str) or source != os.path.abspath(source):
    raise SystemExit(1)
print(json.dumps({"mountpoint": source, "name": name},
                 sort_keys=True, separators=(",", ":")))
' "$expected_container_id" "$expected_config")"; then
    echo "Cannot bind Prometheus data volume from its exact container" >&2
    return 1
  fi
  if ! volume_name="$(printf '%s\n' "$mount_receipt" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["name"])')" \
      || ! volume_record="$(podman volume inspect "$volume_name")" \
      || ! verified_receipt="$(printf '%s\n' "$volume_record" | python3 -c '
import json
import sys

expected = json.loads(sys.argv[1])
payload = json.load(sys.stdin)
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit(1)
record = payload[0]
created_at = record.get("CreatedAt")
if record.get("Name") != expected["name"] \
        or record.get("Mountpoint") != expected["mountpoint"] \
        or record.get("Driver") != "local" \
        or record.get("Scope", "local") != "local" \
        or record.get("Options", {}) not in ({}, None) \
        or not isinstance(created_at, str) or not created_at:
    raise SystemExit(1)
expected["created_at"] = created_at
print(json.dumps(expected, sort_keys=True, separators=(",", ":")))
' "$mount_receipt")"; then
    echo "Prometheus data volume object differs from its mounted identity" >&2
    return 1
  fi
  printf '%s\n' "$verified_receipt"
}

revalidate_prometheus_volume() {
  local receipt="$1" volume_name volume_record
  if ! volume_name="$(printf '%s\n' "$receipt" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["name"])')" \
      || ! volume_record="$(podman volume inspect "$volume_name")"; then
    return 1
  fi
  printf '%s\n' "$volume_record" | python3 -c '
import json
import sys

expected = json.loads(sys.argv[1])
payload = json.load(sys.stdin)
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit(1)
record = payload[0]
raise SystemExit(0 if (
    record.get("Name") == expected["name"]
    and record.get("Mountpoint") == expected["mountpoint"]
    and record.get("CreatedAt") == expected["created_at"]
    and record.get("Driver") == "local"
    and record.get("Scope", "local") == "local"
    and record.get("Options", {}) in ({}, None)
) else 1)
' "$receipt"
}

volume_name_from_receipt() {
  printf '%s\n' "$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["name"])'
}

replace_bound_container() {
  local container_index="$1"
  shift
  local name="${REQUIRED_CONTAINERS[$container_index]}"
  local service="${REQUIRED_SERVICES[$container_index]}"
  local previous_id="${BOUND_CONTAINER_IDS[$container_index]}"
  local rebound_id new_id

  if ! rebound_id="$(bind_one_container "$container_index" "$PROMETHEUS_CONFIG" \
      "$previous_id" "$name" either)" \
      || [ "$rebound_id" != "$previous_id" ]; then
    echo "Refusing to retire a replaced or foreign $name" >&2
    return 1
  fi
  if ! podman rm -f "$previous_id"; then
    echo "Cannot retire bound container $previous_id" >&2
    return 1
  fi
  if ! new_id="$(podman run -d --name "$name" \
      --label "com.docker.compose.project=$STACK_PROJECT" \
      --label "com.docker.compose.service=$service" \
      --label "io.podman.compose.project=$STACK_PROJECT" \
      --label "io.podman.compose.service=$service" \
      --network "$STACK_NETWORK_ID" "$@" \
      "${EXPECTED_IMAGE_IDS[$container_index]}")" \
      || ! [[ "$new_id" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Cannot create replacement for $name" >&2
    return 1
  fi
  BOUND_CONTAINER_IDS[container_index]="$new_id"
  if ! rebound_id="$(bind_one_container "$container_index" "$PROMETHEUS_CONFIG" \
      "$new_id" "$new_id" resolved)" || [ "$rebound_id" != "$new_id" ]; then
    echo "Replacement for $name did not preserve its exact contract" >&2
    return 1
  fi
  if ! rebound_id="$(bind_one_container "$container_index" "$PROMETHEUS_CONFIG" \
      "$new_id" "$name" resolved)" || [ "$rebound_id" != "$new_id" ]; then
    echo "Reserved name $name does not bind the created container" >&2
    return 1
  fi
  record_bound_service_ip "$container_index" "$new_id" || return 1
}

replace_bound_prometheus() {
  local previous_source="$1"
  local container_index=4
  local name="${REQUIRED_CONTAINERS[$container_index]}"
  local service="${REQUIRED_SERVICES[$container_index]}"
  local previous_id="${BOUND_CONTAINER_IDS[$container_index]}"
  local rebound_id new_id volume_receipt confirmed_receipt volume_name

  if ! rebound_id="$(bind_one_container "$container_index" "$previous_source" \
      "$previous_id" "$name" either)" \
      || [ "$rebound_id" != "$previous_id" ]; then
    echo "Refusing to retire a replaced or foreign $name" >&2
    return 1
  fi
  if ! volume_receipt="$(capture_prometheus_volume "$previous_id" \
      "$previous_id" "$previous_source")" \
      || ! confirmed_receipt="$(capture_prometheus_volume "$previous_id" \
          "$previous_id" "$previous_source")" \
      || [ "$confirmed_receipt" != "$volume_receipt" ] \
      || ! volume_name="$(volume_name_from_receipt "$volume_receipt")"; then
    echo "Refusing to retire Prometheus with a changing data volume" >&2
    return 1
  fi
  if ! podman rm -f "$previous_id"; then
    echo "Cannot retire bound container $previous_id" >&2
    return 1
  fi
  if ! revalidate_prometheus_volume "$volume_receipt"; then
    echo "Prometheus data volume changed after container retirement" >&2
    return 1
  fi
  if ! new_id="$(podman run -d --name "$name" \
      --label "com.docker.compose.project=$STACK_PROJECT" \
      --label "com.docker.compose.service=$service" \
      --label "io.podman.compose.project=$STACK_PROJECT" \
      --label "io.podman.compose.service=$service" \
      --network "$STACK_NETWORK_ID" \
      --network-alias prometheus \
      --cpus 2 \
      --cpu-shares 512 \
      --memory 2g \
      --memory-reservation 256m \
      -p 9090:9090 \
      -v "$PROMETHEUS_CONFIG:/etc/prometheus/prometheus.yml:ro" \
      -v "$volume_name:/prometheus" \
      "${EXPECTED_IMAGE_IDS[$container_index]}" \
      --config.file=/etc/prometheus/prometheus.yml \
      --web.enable-lifecycle)" \
      || ! [[ "$new_id" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Cannot create replacement for $name" >&2
    return 1
  fi
  BOUND_CONTAINER_IDS[container_index]="$new_id"
  if ! rebound_id="$(bind_one_container "$container_index" "$PROMETHEUS_CONFIG" \
      "$new_id" "$new_id" resolved)" || [ "$rebound_id" != "$new_id" ]; then
    echo "Replacement for $name did not preserve its exact contract" >&2
    return 1
  fi
  if ! rebound_id="$(bind_one_container "$container_index" "$PROMETHEUS_CONFIG" \
      "$new_id" "$name" resolved)" || [ "$rebound_id" != "$new_id" ]; then
    echo "Reserved name $name does not bind the created container" >&2
    return 1
  fi
  if ! confirmed_receipt="$(capture_prometheus_volume "$new_id" "$new_id" \
      "$PROMETHEUS_CONFIG")" || [ "$confirmed_receipt" != "$volume_receipt" ]; then
    echo "Prometheus replacement did not retain the bound data volume" >&2
    return 1
  fi
  PROMETHEUS_VOLUME_RECEIPT="$volume_receipt"
}

echo "╔══════════════════════════════════════════════╗"
echo "║  Starting HomericIntelligence E2E Stack      ║"
echo "╚══════════════════════════════════════════════╝"

# Reserved names are authority-bearing state. Bind every existing occupant to
# the selected project/service, immutable assets, and exact mounts before any
# Compose or removal effect.
EXISTING_BIND_STATUS=0
bind_existing_stack || EXISTING_BIND_STATUS=$?
if [ "$EXISTING_BIND_STATUS" -gt 1 ]; then
  echo "Existing reserved container state is not owned by this stack" >&2
  exit 1
fi
PREEXISTING_CONTAINER_IDS=("${BOUND_CONTAINER_IDS[@]}")

# Skip bring-up only when every selected container and public health surface
# proves the complete requested stack is already ready.
if [ "$EXISTING_BIND_STATUS" -eq 0 ] && stack_is_ready >/dev/null 2>&1; then
  if revalidate_bound_stack __existing__; then
    echo "Stack already running — skipping bring-up."
    exit 0
  fi
  echo "Existing stack ownership changed during readiness validation" >&2
  exit 1
fi

# Compose substitution is invocation-scoped. Never rewrite the repository's
# operator-owned .env or its tracked Prometheus example.
if [ -n "${BOUND_CONTAINER_IDS[4]:-}" ]; then
  adopt_bound_runtime_config
else
  prepare_runtime_config
fi

# ── Step 1: Bring up everything via compose ──
echo "Starting all services via compose..."
if ! runtime_config_transaction verify "$RUNTIME_DIRECTORY" \
    "$RUNTIME_DIRECTORY_ID" "$PROMETHEUS_CONFIG_NAME" \
    "$PROMETHEUS_CONFIG_ID" \
    || ! revalidate_existing_bindings; then
  echo "E2E runtime or container authority changed before Compose" >&2
  exit 1
fi
export COMPOSE_PROJECT_NAME="$STACK_PROJECT"
export PODMAN_COMPOSE_NAME_SEPARATOR_COMPAT=true
podman compose -f "$COMPOSE_FILE" up -d --no-recreate 2>&1 | tail -10
echo "Waiting 10s for services to initialize..."
sleep 10

if ! bind_complete_stack "$PROMETHEUS_CONFIG"; then
  echo "Compose result failed immutable ownership validation" >&2
  exit 1
fi

# ── Step 2: Confirm dependency IPs (stable — neither was restarted) ──
NATS_IP="$(container_ip "${BOUND_CONTAINER_IDS[0]}")"
NESTOR_IP="$(container_ip "${BOUND_CONTAINER_IDS[2]}")"
echo "NATS=$NATS_IP  Nestor=$NESTOR_IP"

# ── Step 3: Restart NATS-dependent services with direct IPs ──
echo "Restarting services with direct NATS IP (podman DNS workaround)..."

# Agamemnon (C++)
replace_bound_container 1 \
  --cpus 2 \
  --cpu-shares 256 \
  --memory 1g \
  --memory-reservation 128m \
  -p 8080:8080 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  --health-cmd "wget -qO- http://localhost:8080/v1/health 2>/dev/null || exit 1" \
  --health-interval 5s \
  --health-timeout 3s \
  --health-retries 10 \
  --health-start-period 10s

AGAMEMNON_IP="$(container_ip "${BOUND_CONTAINER_IDS[1]}")"

# Hermes (Python)
replace_bound_container 3 \
  --cpus 1 \
  --cpu-shares 256 \
  --memory 512m \
  --memory-reservation 128m \
  -p 8085:8085 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  -e "HERMES_PORT=8085" \
  --health-cmd "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:8085/health')\" 2>/dev/null || exit 1" \
  --health-interval 5s \
  --health-timeout 3s \
  --health-retries 10 \
  --health-start-period 10s

# Hello Myrmidon (C++)
replace_bound_container 8 \
  --cpus 2 \
  --cpu-shares 256 \
  --memory 1g \
  --memory-reservation 128m \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  -e "AGAMEMNON_URL=http://${AGAMEMNON_IP}:8080" \
  --restart on-failure:5

# Wait for Agamemnon to start
sleep 5
AGAMEMNON_IP="$(container_ip "${BOUND_CONTAINER_IDS[1]}")"
echo "Agamemnon=$AGAMEMNON_IP"

# Argus Exporter (Python — needs Agamemnon + Nestor + NATS IPs)
replace_bound_container 7 \
  --cpus 1 \
  --cpu-shares 256 \
  --memory 512m \
  --memory-reservation 128m \
  -p 9100:9100 \
  -e "AGAMEMNON_URL=http://${AGAMEMNON_IP}:8080" \
  -e "NESTOR_URL=http://${NESTOR_IP}:8081" \
  -e "NATS_URL=http://${NATS_IP}:8222"

# ── Step 4: Patch Prometheus config with resolved argus-exporter IP ──
sleep 3
ARGUS_IP="$(container_ip "${BOUND_CONTAINER_IDS[7]}")"
if [ -n "$ARGUS_IP" ]; then
  previous_prometheus_config="$PROMETHEUS_CONFIG"
  if ! generation_receipt="$(runtime_config_transaction render-publish \
      "$RUNTIME_DIRECTORY" "$RUNTIME_DIRECTORY_ID" \
      "$PROMETHEUS_CONFIG_NAME" "$PROMETHEUS_CONFIG_ID" \
      "$ODYSSEUS_ROOT/e2e/prometheus.yml" "$ARGUS_IP")"; then
    echo "Prometheus runtime config destination became unsafe" >&2
    exit 1
  fi
  read -r PROMETHEUS_CONFIG_NAME PROMETHEUS_CONFIG_ID <<<"$generation_receipt"
  if [ -z "$PROMETHEUS_CONFIG_NAME" ] || [ -z "$PROMETHEUS_CONFIG_ID" ]; then
    echo "Prometheus generation transaction returned an incomplete receipt" >&2
    exit 1
  fi
  PROMETHEUS_CONFIG="$RUNTIME_DIRECTORY/$PROMETHEUS_CONFIG_NAME"
  export PROMETHEUS_CONFIG
  if ! runtime_config_transaction verify "$RUNTIME_DIRECTORY" \
      "$RUNTIME_DIRECTORY_ID" "$PROMETHEUS_CONFIG_NAME" \
      "$PROMETHEUS_CONFIG_ID"; then
    echo "Published Prometheus generation failed receipt verification" >&2
    exit 1
  fi
  if ! replace_bound_prometheus "$previous_prometheus_config"; then
    echo "Prometheus generation could not be activated" >&2
    exit 1
  fi
  echo "Prometheus config activated: argus-exporter=${ARGUS_IP}"
else
  echo "Argus exporter has no container IP" >&2
  exit 1
fi

# ── Step 5: Wait and verify ──
echo "Waiting 10s for connections..."
sleep 10

echo ""
echo "=== Service Status ==="
if ! podman ps --format '{{.Names}} {{.Status}}' | grep odysseus | sort; then
  echo "Required container status inventory unavailable" >&2
  exit 1
fi

echo ""
echo "=== Health Checks ==="
READINESS_FAILURES=0
if ! revalidate_bound_stack "$PROMETHEUS_CONFIG" final; then
  echo "Selected container ownership changed before readiness" >&2
  exit 1
fi
for ((container_index = 0; container_index < ${#REQUIRED_CONTAINERS[@]}; container_index++)); do
  container_name="${REQUIRED_CONTAINERS[$container_index]}"
  if container_is_running "${BOUND_CONTAINER_IDS[$container_index]}"; then
    echo "$container_name: OK"
  else
    echo "$container_name: FAIL"
    READINESS_FAILURES=$((READINESS_FAILURES + 1))
  fi
done
if json_field_equals http://localhost:8080/v1/health status ok; then
  echo "Agamemnon: OK"
else
  echo "Agamemnon: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if json_field_equals http://localhost:8081/v1/health status ok; then
  echo "Nestor: OK"
else
  echo "Nestor: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if curl_http_response 15 http://localhost:8085/health \
  | http_response_matches hermes; then
  echo "Hermes: OK"
else
  echo "Hermes: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if curl_http_response 15 http://localhost:8222/healthz \
  | http_response_matches nats; then
  echo "NATS: OK"
else
  echo "NATS: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if curl_http_response 15 http://localhost:9090/-/healthy \
  | http_response_matches prometheus; then
  echo "Prometheus: OK"
else
  echo "Prometheus: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if json_field_equals http://localhost:3001/api/health database ok; then
  echo "Grafana: OK"
else
  echo "Grafana: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi
if curl_http_response 15 http://localhost:9100/metrics \
  | http_response_matches argus; then
  echo "Argus exporter: OK"
else
  echo "Argus exporter: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi

echo ""
echo "=== NATS Connections ==="
if curl_http_response 15 http://localhost:8222/varz \
  | http_response_matches varz-print; then
  :
else
  echo "NATS connection evidence: FAIL"
  READINESS_FAILURES=$((READINESS_FAILURES + 1))
fi

if [ "$READINESS_FAILURES" -ne 0 ]; then
  echo ""
  echo "Stack not ready: $READINESS_FAILURES required checks failed" >&2
  exit 1
fi
if ! runtime_config_transaction verify "$RUNTIME_DIRECTORY" \
    "$RUNTIME_DIRECTORY_ID" "$PROMETHEUS_CONFIG_NAME" \
    "$PROMETHEUS_CONFIG_ID" \
    || [ -z "$PROMETHEUS_VOLUME_RECEIPT" ] \
    || ! revalidate_prometheus_volume "$PROMETHEUS_VOLUME_RECEIPT" \
    || ! revalidate_bound_stack "$PROMETHEUS_CONFIG" final; then
  echo "Stack authority changed at the terminal readiness boundary" >&2
  exit 1
fi

echo ""
echo "Stack ready. Run: just e2e-test"
