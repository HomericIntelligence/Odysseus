#!/usr/bin/env bash
# Hermetic behavior tests for truthful start-stack readiness.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

if ! TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || [ -z "$TMP_BASE" ]; then
    printf '%s\n' 'ERROR: could not resolve start-stack health fixture parent' >&2
    exit 1
fi
TMP_PREFIX="$TMP_BASE/odysseus-start-stack-health."
TMP=""
TMP_VALID=false

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

cleanup_fixture() {
    local suffix
    [ "$TMP_VALID" = true ] || return
    suffix="${TMP#"$TMP_PREFIX"}"
    if [ -z "$TMP" ] || [ "$suffix" = "$TMP" ] || [ -z "$suffix" ] \
        || [ ! -d "$TMP" ] || [ -L "$TMP" ]; then
        printf 'ERROR: refusing unsafe start-stack health fixture cleanup: %s\n' \
            "$TMP" >&2
        return
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*)
            printf 'ERROR: refusing unsafe start-stack health fixture cleanup: %s\n' \
                "$TMP" >&2
            return
            ;;
    esac
    if ! rm -r -- "$TMP"; then
        printf 'ERROR: failed to remove start-stack health fixture: %s\n' \
            "$TMP" >&2
    fi
}

if ! TMP="$(make_fixture_directory "$TMP_PREFIX")"; then
    printf '%s\n' 'ERROR: could not create start-stack health fixture' >&2
    exit 1
fi
TMP_VALID=true
trap cleanup_fixture EXIT
FIXTURE="$TMP/repo"
FAKE_BIN="$TMP/bin"
PODMAN_LOG="$TMP/podman.log"
CURL_LOG="$TMP/curl.log"
STACK_STARTED="$TMP/stack.started"
PODMAN_STATE_DIR="$TMP/podman-state"
CONTAINER_VICTIM="$TMP/container-victim"
EXISTING_RUNTIME_DIR="$TMP/existing-runtime"
EXISTING_PROMETHEUS_CONFIG="$EXISTING_RUNTIME_DIR/prometheus.runtime.yml"
PROTECTED_ENV="$FIXTURE/.env"
PROTECTED_PROMETHEUS="$FIXTURE/e2e/prometheus.runtime.yml"
mkdir -p "$FIXTURE/e2e/lib" "$FIXTURE/infrastructure/Hermes" \
    "$FIXTURE/infrastructure/Argus" "$FIXTURE/provisioning/Myrmidons" \
    "$FAKE_BIN" "$PODMAN_STATE_DIR" "$EXISTING_RUNTIME_DIR"
EXPECTED_ARGUS_ROOT="$(cd "$FIXTURE/infrastructure/Argus" && pwd -P)"
chmod 700 "$EXISTING_RUNTIME_DIR"
printf '%s\n' 'targets: ["argus-exporter:9100"]' > "$EXISTING_PROMETHEUS_CONFIG"
chmod 644 "$EXISTING_PROMETHEUS_CONFIG"
cp "$ROOT/e2e/start-stack.sh" "$FIXTURE/e2e/start-stack.sh"
cp "$ROOT/e2e/lib/common.sh" "$FIXTURE/e2e/lib/common.sh"
printf '%s\n' \
    'global:' \
    '  scrape_interval: 15s' \
    'scrape_configs:' \
    '  - targets: ["argus-exporter:9100"]' \
    > "$FIXTURE/e2e/prometheus.yml"
printf '%s\n' 'services: {}' > "$FIXTURE/docker-compose.e2e.yml"

reset_protected_files() {
    printf '%s\n' 'operator-owned-env' > "$PROTECTED_ENV"
    printf '%s\n' 'tracked-runtime-sentinel' > "$PROTECTED_PROMETHEUS"
}

protected_files_are_unchanged() {
    [ "$(cat "$PROTECTED_ENV")" = operator-owned-env ] \
        && [ "$(cat "$PROTECTED_PROMETHEUS")" = tracked-runtime-sentinel ]
}

rejected_destination_is_unchanged() {
    case "$1" in
        symlink)
            [ -L "$2/prometheus.runtime.yml" ] \
                && [ "$(cat "$3")" = do-not-overwrite ]
            ;;
        directory) [ -d "$2/prometheus.runtime.yml" ] ;;
        regular) [ "$(cat "$2/prometheus.runtime.yml")" = operator-owned-runtime ] ;;
        *) return 1 ;;
    esac
}

cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/sed" <<'SH'
#!/usr/bin/env bash
/usr/bin/sed "$@"
sed_status=$?
[ "$sed_status" -eq 0 ] || exit "$sed_status"

case "${RUNTIME_RACE:-}" in
    hardlink)
        rm -f "$RUNTIME_CONFIG"
        ln "$RUNTIME_VICTIM" "$RUNTIME_CONFIG"
        ;;
    symlink)
        rm -f "$RUNTIME_CONFIG"
        ln -s "$RUNTIME_VICTIM" "$RUNTIME_CONFIG"
        ;;
    ancestor)
        mv "$RUNTIME_ANCESTOR" "$RUNTIME_MOVED_ANCESTOR"
        mv "$RUNTIME_REPLACEMENT_ANCESTOR" "$RUNTIME_ANCESTOR"
        ;;
    "") exit 0 ;;
    *) exit 97 ;;
esac
: > "$RUNTIME_RACE_MARKER"
SH

cat > "$FAKE_BIN/podman" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PODMAN_LOG"

container_names=(
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
container_services=(
    nats agamemnon nestor hermes prometheus loki grafana argus-exporter hello-myrmidon
)
image_refs=(
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

container_id() { printf '%064d' "$(( $1 + 1 ))"; }
replacement_id() { printf '%064d' "$(( $1 + 51 ))"; }
image_id() { printf 'sha256:%064x' "$(( $1 + 17 ))"; }
network_id() { printf '%064x' 170; }

index_for_name() {
    local candidate
    for ((candidate = 0; candidate < ${#container_names[@]}; candidate++)); do
        if [ "${container_names[$candidate]}" = "$1" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

index_for_target() {
    local candidate target="$1"
    if candidate="$(index_for_name "$target")"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for ((candidate = 0; candidate < ${#container_names[@]}; candidate++)); do
        if [ "$(container_id "$candidate")" = "$target" ] \
            || [ "$(replacement_id "$candidate")" = "$target" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

case "${1:-}" in
    compose)
        printf 'PROMETHEUS_CONFIG=%s\n' "${PROMETHEUS_CONFIG:-}" >> "$PODMAN_LOG"
        printf 'PODMAN_COMPOSE_NAME_SEPARATOR_COMPAT=%s\n' \
            "${PODMAN_COMPOSE_NAME_SEPARATOR_COMPAT:-}" >> "$PODMAN_LOG"
        printf '%s\n' "${PROMETHEUS_CONFIG:-}" \
            > "$PODMAN_STATE_DIR/compose-prometheus-source"
        : > "$STACK_STARTED"
        exit 0
        ;;
    container)
        [ "${2:-}" = exists ] || exit 125
        existing_index="$(index_for_name "${3:-}")" || exit 1
        if [ "${CONTAINER_EXISTENCE_SCENARIO:-all}" = none ] \
            && [ ! -e "$STACK_STARTED" ]; then
            exit 1
        fi
        if [ "${CONTAINER_EXISTENCE_SCENARIO:-all}" = partial_assets ] \
            && [ ! -e "$STACK_STARTED" ] && [ "$existing_index" -ne 0 ]; then
            exit 1
        fi
        exit 0
        ;;
    image)
        [ "${2:-}" = inspect ] || exit 125
        target="${!#}"
        for ((index = 0; index < ${#image_refs[@]}; index++)); do
            if [ "${image_refs[$index]}" = "$target" ]; then
                if [ "${CONTAINER_EXISTENCE_SCENARIO:-all}" = partial_assets ] \
                    && [ ! -e "$STACK_STARTED" ] && [ "$index" -ne 0 ]; then
                    exit 1
                fi
                case "${4:-}" in
                    '{{.Id}}')
                        image_id "$index"
                        printf '\n'
                        ;;
                    '{{json .Config.Volumes}}')
                        case "$index" in
                            4) printf '%s\n' '{"/prometheus":{}}' ;;
                            6) printf '%s\n' '{"/var/lib/grafana":{}}' ;;
                            *) printf '%s\n' '{}' ;;
                        esac
                        ;;
                    '{{json .Config}}')
                        python3 - "${container_services[$index]}" <<'PY'
import json
import sys

service = sys.argv[1]
image_exposed_ports = {
    "nats": {"4222/tcp": {}, "6222/tcp": {}, "8222/tcp": {}},
}.get(service, {})
image_user = {
    "prometheus": "nobody",
    "loki": "10001",
    "grafana": "472",
}.get(service, "")
json.dump({
    "Env": ["PATH=/usr/bin"],
    "User": image_user,
    "Cmd": [f"/fixture/{service}"],
    "Entrypoint": ["/fixture-entrypoint"],
    "ExposedPorts": image_exposed_ports,
}, sys.stdout)
print()
PY
                        ;;
                    *) exit 125 ;;
                esac
                exit 0
            fi
        done
        exit 1
        ;;
    network)
        [ "${2:-}" = inspect ] || exit 125
        if [ "${3:-}" = --format ]; then
            [ "${4:-}" = '{{.ID}}' ] || exit 125
            network_id
            printf '\n'
            exit 0
        fi
        python3 - "$PODMAN_STATE_DIR" "$(network_id)" \
            "${CONTAINER_METADATA_SCENARIO:-valid}" <<'PY'
import json
import os
import sys

state_dir, network_id, scenario = sys.argv[1:]
names = [
    "odysseus-nats-1",
    "odysseus-agamemnon-1",
    "odysseus-nestor-1",
    "odysseus-hermes-1",
    "odysseus-prometheus-1",
    "odysseus-loki-1",
    "odysseus-grafana-1",
    "odysseus-argus-exporter-1",
    "odysseus-hello-myrmidon-1",
]
members = {}
for index, name in enumerate(names):
    if scenario == "foreign_network_membership" and index == 1:
        continue
    offset = index + (51 if os.path.exists(os.path.join(state_dir, f"replaced-{index}")) else 1)
    members[f"{offset:064d}"] = {"name": name}
foreign_member_name = (
    "odysseus-nats-1" if scenario == "compose_aba"
    else "odysseus-agamemnon-1"
)
members[f"{255:064x}"] = {"name": foreign_member_name}
json.dump([{
    "id": network_id,
    "name": "odysseus_homeric-mesh",
    "containers": members,
}], sys.stdout)
print()
PY
        exit 0
        ;;
    volume)
        [ "${2:-}" = inspect ] || exit 125
        volume_name="${3:-}"
        [ "$volume_name" = odysseus-prometheus-data ] || exit 1
        count_file="$PODMAN_STATE_DIR/volume-inspect"
        count=0
        [ ! -f "$count_file" ] || read -r count < "$count_file"
        count=$((count + 1))
        printf '%s\n' "$count" > "$count_file"
        mountpoint=/volumes/odysseus-prometheus-data/_data
        created_at=2026-09-15T00:00:00.000000000Z
        if [ "${CONTAINER_METADATA_SCENARIO:-valid}" = volume_aba ] \
            && [ "$count" -ge 2 ]; then
            created_at=2026-09-15T00:00:01.000000000Z
        fi
        python3 - "$volume_name" "$mountpoint" "$created_at" <<'PY'
import json
import sys

json.dump([{
    "Name": sys.argv[1],
    "Driver": "local",
    "Mountpoint": sys.argv[2],
    "CreatedAt": sys.argv[3],
    "Options": {},
    "Scope": "local",
}], sys.stdout)
print()
PY
        exit 0
        ;;
    rm)
        target="${!#}"
        index="$(index_for_target "$target")" || exit 1
        [ "$(container_id "$index")" = "$target" ] || exit 1
        : > "$PODMAN_STATE_DIR/removed-$index"
        exit 0
        ;;
    run)
        name=""
        has_replace=false
        previous=""
        for argument in "$@"; do
            if [ "$previous" = --name ]; then name="$argument"; fi
            [ "$argument" = --replace ] && has_replace=true
            previous="$argument"
        done
        index="$(index_for_name "$name")" || exit 125
        if [ "$has_replace" = true ]; then
            printf '%s\n' 'destructive-name-replacement' > "$PODMAN_VICTIM"
            replacement_id "$index"
            printf '\n'
            exit 0
        fi
        [ -e "$PODMAN_STATE_DIR/removed-$index" ] || exit 125
        expected_args=(
            run -d --name "$name"
            --label com.docker.compose.project=odysseus
            --label "com.docker.compose.service=${container_services[$index]}"
            --label io.podman.compose.project=odysseus
            --label "io.podman.compose.service=${container_services[$index]}"
            --network "$(network_id)"
        )
        case "$index" in
          1)
            expected_args+=(
                --cpus 2 --cpu-shares 256
                --memory 1g --memory-reservation 128m
                -p 8080:8080
                -e NATS_URL=nats://10.0.0.2:4222
                --health-cmd 'wget -qO- http://localhost:8080/v1/health 2>/dev/null || exit 1'
                --health-interval 5s --health-timeout 3s
                --health-retries 10 --health-start-period 10s
                "$(image_id "$index")"
            )
            ;;
          3)
            expected_args+=(
                --cpus 1 --cpu-shares 256
                --memory 512m --memory-reservation 128m
                -p 8085:8085
                -e NATS_URL=nats://10.0.0.2:4222
                -e HERMES_PORT=8085
                --health-cmd 'python3 -c "import urllib.request; urllib.request.urlopen('\''http://localhost:8085/health'\'')" 2>/dev/null || exit 1'
                --health-interval 5s --health-timeout 3s
                --health-retries 10 --health-start-period 10s
                "$(image_id "$index")"
            )
            ;;
          4)
            expected_args+=(
                --network-alias prometheus
                --cpus 2 --cpu-shares 512
                --memory 2g --memory-reservation 256m
                -p 9090:9090
                -v "$PROMETHEUS_CONFIG:/etc/prometheus/prometheus.yml:ro"
                -v odysseus-prometheus-data:/prometheus
                "$(image_id "$index")"
                --config.file=/etc/prometheus/prometheus.yml
                --web.enable-lifecycle
            )
            ;;
          7)
            expected_args+=(
                --cpus 1 --cpu-shares 256
                --memory 512m --memory-reservation 128m
                -p 9100:9100
                -e AGAMEMNON_URL=http://10.0.0.3:8080
                -e NESTOR_URL=http://10.0.0.4:8081
                -e NATS_URL=http://10.0.0.2:8222
                "$(image_id "$index")"
            )
            ;;
          8)
            expected_args+=(
                --cpus 2 --cpu-shares 256
                --memory 1g --memory-reservation 128m
                -e NATS_URL=nats://10.0.0.2:4222
                -e AGAMEMNON_URL=http://10.0.0.3:8080
                --restart on-failure:5
                "$(image_id "$index")"
            )
            ;;
          *) exit 125 ;;
        esac
        actual_args=("$@")
        [ "${#actual_args[@]}" -eq "${#expected_args[@]}" ] || exit 125
        for ((argument_index = 0;
              argument_index < ${#expected_args[@]};
              argument_index++)); do
            [ "${actual_args[$argument_index]}" = \
                "${expected_args[$argument_index]}" ] || exit 125
        done
        : > "$PODMAN_STATE_DIR/replaced-$index"
        replacement_id "$index"
        printf '\n'
        exit 0
        ;;
    inspect)
        if [ "${2:-}" = --format ]; then
            target="${4:-}"
            index="$(index_for_target "$target")" || exit 1
            if [ "${CONTAINER_SCENARIO:-running}" = stopped ] \
                && [ "${container_services[$index]}" = hermes ]; then
                printf '%s\n' false
            else
                printf '%s\n' true
            fi
            exit 0
        fi

        target="${2:-}"
        index="$(index_for_target "$target")" || exit 1
        name="${container_names[$index]}"
        service="${container_services[$index]}"
        if [ -e "$PODMAN_STATE_DIR/replaced-$index" ]; then
            id="$(replacement_id "$index")"
            replaced=true
        else
            id="$(container_id "$index")"
            replaced=false
        fi
        actual_name="$name"
        project_label=odysseus
        podman_project_label=odysseus
        service_label="$service"
        immutable_image="$(image_id "$index")"
        attached_network=odysseus_homeric-mesh

        if [ "$target" = "$name" ]; then
            count_file="$PODMAN_STATE_DIR/inspect-$index"
            count=0
            [ ! -f "$count_file" ] || read -r count < "$count_file"
            count=$((count + 1))
            printf '%s\n' "$count" > "$count_file"
        else
            count=0
        fi

        case "${CONTAINER_METADATA_SCENARIO:-valid}:$service" in
            foreign_label:hermes) project_label=foreign ;;
            foreign_podman_label:hermes) podman_project_label=foreign ;;
            docker_only_labels:*) podman_project_label=__absent__ ;;
            foreign_image:agamemnon) immutable_image="sha256:$(printf '%064x' 255)" ;;
            foreign_name:agamemnon) actual_name=foreign-agamemnon ;;
            foreign_network:agamemnon) attached_network=foreign-network ;;
            aba:agamemnon)
                if [ "$target" = "$name" ] && [ "$count" -ge 3 ]; then
                    id="$(printf '%064x' 255)"
                    project_label=foreign
                fi
                ;;
            fast_path_aba:agamemnon)
                if [ "$target" = "$name" ] && [ "$count" -ge 2 ]; then
                    id="$(printf '%064x' 255)"
                    project_label=foreign
                fi
                ;;
            compose_aba:nats)
                if [ "$target" = "$name" ] && [ "$count" -ge 3 ]; then
                    id="$(printf '%064x' 255)"
                fi
                ;;
        esac

        if [ -e "$PODMAN_STATE_DIR/replaced-4" ]; then
            prometheus_source="$PROMETHEUS_CONFIG"
        elif [ -e "$PODMAN_STATE_DIR/compose-prometheus-source" ]; then
            read -r prometheus_source \
                < "$PODMAN_STATE_DIR/compose-prometheus-source"
        else
            prometheus_source="$EXISTING_PROMETHEUS_CONFIG"
        fi
        if [ "${CONTAINER_METADATA_SCENARIO:-valid}" = foreign_mount ] \
            && [ "$service" = prometheus ]; then
            prometheus_source="$PODMAN_VICTIM"
        fi
        running=true
        if [ "${CONTAINER_SCENARIO:-running}" = stopped ] && [ "$service" = hermes ]; then
            running=false
        fi

        python3 - "$actual_name" "$id" "$service" "$project_label" \
            "$service_label" "$immutable_image" \
            "$podman_project_label" \
            "$prometheus_source" "$EXPECTED_PROJECT_ROOT/e2e/grafana/provisioning" \
            "$EXPECTED_ARGUS_DIR/dashboards" "$running" "$index" \
            "$attached_network" "$replaced" <<'PY'
import json
import os
import sys

(name, container_id, service, project_label, service_label, image_id,
 podman_project_label,
 prometheus_source, grafana_provisioning, grafana_dashboards,
 running, index, attached_network, replaced) = sys.argv[1:]
scenario = os.environ.get("CONTAINER_METADATA_SCENARIO", "valid")
mounts = []
if service == "prometheus":
    mounts = [
        {
            "Type": "bind",
            "Source": prometheus_source,
            "Destination": "/etc/prometheus/prometheus.yml",
            "RW": False,
        },
        {
            "Type": "volume",
            "Name": "odysseus-prometheus-data",
            "Source": "/volumes/odysseus-prometheus-data/_data",
            "Destination": "/prometheus",
            "RW": True,
        },
    ]
elif service == "grafana":
    mounts = [
        {
            "Type": "bind",
            "Source": grafana_provisioning,
            "Destination": "/etc/grafana/provisioning",
            "RW": False,
        },
        {
            "Type": "bind",
            "Source": grafana_dashboards,
            "Destination": "/var/lib/grafana/dashboards",
            "RW": False,
        },
        {
            "Type": "volume",
            "Name": "odysseus-grafana-data",
            "Source": "/volumes/odysseus-grafana-data/_data",
            "Destination": "/var/lib/grafana",
            "RW": True,
        },
    ]
labels = {
    "com.docker.compose.project": project_label,
    "com.docker.compose.service": service_label,
}
if podman_project_label != "__absent__":
    labels.update({
        "io.podman.compose.project": podman_project_label,
        "io.podman.compose.service": service_label,
    })

image_environment = ["PATH=/usr/bin"]
runtime_home = {
    "prometheus": "/home",
    "loki": "/home/loki",
    "grafana": "/home/grafana",
}.get(service, "/root")
runtime_environment = [
    "TERM=xterm",
    "container=podman",
    f"HOME={runtime_home}",
    f"HOSTNAME={container_id[:12]}",
]
if scenario == "docker_only_labels":
    runtime_environment.remove("TERM=xterm")
    runtime_environment.append(f"HTTP_PROXY={os.environ['HTTP_PROXY']}")
image_command = [f"/fixture/{service}"]
image_entrypoint = ["/fixture-entrypoint"]
service_environment = {
    "agamemnon": ["NATS_URL=nats://nats:4222"],
    "nestor": ["NATS_URL=nats://nats:4222"],
    "hermes": ["NATS_URL=nats://nats:4222", "HERMES_PORT=8085"],
    "grafana": [
        "GF_AUTH_ANONYMOUS_ENABLED=false",
        "GF_SECURITY_ADMIN_PASSWORD=e2e-not-for-prod",
        "GF_SECURITY_ALLOW_EMBEDDING=true",
        "GF_ANALYTICS_REPORTING_ENABLED=false",
        "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
        "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false",
    ],
    "argus-exporter": [
        "AGAMEMNON_URL=http://agamemnon:8080",
        "NESTOR_URL=http://nestor:8081",
        "NATS_URL=http://nats:8222",
    ],
    "hello-myrmidon": [
        "NATS_URL=nats://nats:4222",
        "AGAMEMNON_URL=http://agamemnon:8080",
    ],
}
if replaced == "true":
    service_environment.update({
        "agamemnon": ["NATS_URL=nats://10.0.0.2:4222"],
        "hermes": ["NATS_URL=nats://10.0.0.2:4222", "HERMES_PORT=8085"],
        "argus-exporter": [
            "AGAMEMNON_URL=http://10.0.0.3:8080",
            "NESTOR_URL=http://10.0.0.4:8081",
            "NATS_URL=http://10.0.0.2:8222",
        ],
        "hello-myrmidon": [
            "NATS_URL=nats://10.0.0.2:4222",
            "AGAMEMNON_URL=http://10.0.0.3:8080",
        ],
    })
command_overrides = {
    "nats": ["-js", "-m", "8222"],
    "prometheus": [
        "--config.file=/etc/prometheus/prometheus.yml",
        "--web.enable-lifecycle",
    ],
    "loki": ["-config.file=/etc/loki/local-config.yaml"],
}
published_ports = {
    "nats": [("4222/tcp", "4222"), ("8222/tcp", "8222")],
    "agamemnon": [("8080/tcp", "8080")],
    "nestor": [("8081/tcp", "8081")],
    "hermes": [("8085/tcp", "8085")],
    "prometheus": [("9090/tcp", "9090")],
    "loki": [("3100/tcp", "3100")],
    "grafana": [("3000/tcp", "3001")],
    "argus-exporter": [("9100/tcp", "9100")],
    "hello-myrmidon": [],
}
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
healthchecks = {
    "nats": {
        "Test": [
            "CMD", "sh", "-c",
            "wget -q --spider http://localhost:8222/healthz 2>/dev/null || exit 1",
        ],
        "Interval": 5_000_000_000,
        "Timeout": 3_000_000_000,
        "Retries": 10,
        "StartPeriod": 5_000_000_000,
    },
    "agamemnon": {
        "Test": [
            "CMD", "sh", "-c",
            "wget -qO- http://localhost:8080/v1/health 2>/dev/null || exit 1",
        ],
        "Interval": 5_000_000_000,
        "Timeout": 3_000_000_000,
        "Retries": 10,
        "StartPeriod": 10_000_000_000,
    },
    "nestor": {
        "Test": [
            "CMD", "sh", "-c",
            "wget -qO- http://localhost:8081/v1/health 2>/dev/null || exit 1",
        ],
        "Interval": 5_000_000_000,
        "Timeout": 3_000_000_000,
        "Retries": 10,
        "StartPeriod": 10_000_000_000,
    },
    "hermes": {
        "Test": [
            "CMD", "sh", "-c",
            "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:8085/health')\" 2>/dev/null || exit 1",
        ],
        "Interval": 5_000_000_000,
        "Timeout": 3_000_000_000,
        "Retries": 10,
        "StartPeriod": 10_000_000_000,
    },
}

environment = image_environment + runtime_environment + service_environment.get(service, [])
command = command_overrides.get(service, image_command)
entrypoint = image_entrypoint
healthcheck = healthchecks.get(service)
port_bindings = {
    container_port: [{"HostIp": "", "HostPort": host_port}]
    for container_port, host_port in published_ports[service]
}
nano_cpus, direct_cpu_shares, memory, memory_reservation = resources[service]
cpu_shares = direct_cpu_shares if replaced == "true" else 0
restart_policy = {
    "Name": "on-failure" if service == "hello-myrmidon" else "no",
    "MaximumRetryCount": (
        5 if service == "hello-myrmidon" and replaced == "true" else 0
    ),
}
health_on_failure = "none"

if scenario == "foreign_config_env" and service == "argus-exporter":
    environment.append("UNEXPECTED_RUNTIME_ENV=foreign")
elif scenario == "foreign_config_cmd" and service == "hermes":
    command = ["/fixture/foreign-command"]
elif scenario == "foreign_config_entrypoint" and service == "argus-exporter":
    entrypoint = ["/fixture/foreign-entrypoint"]
elif scenario == "foreign_ports" and service == "agamemnon":
    port_bindings = {"8080/tcp": [{"HostIp": "", "HostPort": "18080"}]}
elif scenario == "foreign_resources" and service == "agamemnon":
    memory_reservation = 0
elif scenario == "foreign_restart" and service == "hello-myrmidon":
    restart_policy = {"Name": "no", "MaximumRetryCount": 0}
elif scenario == "foreign_health" and service == "hermes":
    health_on_failure = "restart"
elif scenario == "missing_hello_agamemnon_url" and service == "hello-myrmidon":
    environment = [
        item for item in environment if not item.startswith("AGAMEMNON_URL=")
    ]

image_exposed_ports = {
    "nats": {"4222/tcp", "6222/tcp", "8222/tcp"},
}.get(service, set())
exposed_ports = image_exposed_ports | set(port_bindings)
network_ports = dict(port_bindings)
for container_port in image_exposed_ports:
    network_ports.setdefault(container_port, None)
config = {
    "Labels": labels,
    "Hostname": container_id[:12],
    "Env": environment,
    "Cmd": command,
    "Entrypoint": entrypoint,
    "ExposedPorts": {container_port: {} for container_port in exposed_ports},
    "StartupHealthCheck": None,
    "HealthcheckOnFailureAction": health_on_failure,
    "HealthLogDestination": "local",
    "HealthcheckMaxLogCount": 5,
    "HealthcheckMaxLogSize": 500,
}
if healthcheck is not None:
    config["Healthcheck"] = healthcheck
record = {
    "Id": container_id,
    "Name": "/" + name,
    "Image": image_id,
    "Config": config,
    "HostConfig": {
        "PortBindings": port_bindings,
        "NanoCpus": nano_cpus,
        "CpuShares": cpu_shares,
        "Memory": memory,
        "MemoryReservation": memory_reservation,
        "RestartPolicy": restart_policy,
    },
    "State": {"Running": running == "true"},
    "NetworkSettings": {"Networks": {
        attached_network: {
            "NetworkID": attached_network,
            "IPAddress": f"10.0.0.{int(index) + 2}",
        }
    }},
    "Mounts": mounts,
}
record["NetworkSettings"]["Ports"] = network_ports
json.dump([record], sys.stdout)
print()
PY
        exit 0
        ;;
    ps)
        printf '%s\n' \
            'odysseus-nats-1 Up' \
            'odysseus-agamemnon-1 Up' \
            'odysseus-nestor-1 Up' \
            'odysseus-hermes-1 Up' \
            'odysseus-prometheus-1 Up' \
            'odysseus-loki-1 Up' \
            'odysseus-grafana-1 Up' \
            'odysseus-argus-exporter-1 Up' \
            'odysseus-hello-myrmidon-1 Up'
        exit 0
        ;;
esac
exit 125
SH

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
url=""
connect_timeout=""
max_time=""
write_out=""
output_target=""
previous=""
for argument in "$@"; do
    case "$argument" in http://*) url="$argument" ;; esac
    case "$previous" in
        --connect-timeout) connect_timeout="$argument" ;;
        --max-time) max_time="$argument" ;;
        --write-out|-w) write_out="$argument" ;;
        --output|-o) output_target="$argument" ;;
    esac
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

is_started=false
[ -e "$STACK_STARTED" ] && is_started=true
case "${HEALTH_SCENARIO:-healthy}:$is_started:$url" in
    partial:false:http://localhost:8080/v1/health)
        printf '%s\n' '{"status":"ok"}'
        exit 0
        ;;
    partial:false:*) exit 22 ;;
    post_failure:false:*) exit 22 ;;
    post_failure:true:http://localhost:8085/health) exit 22 ;;
    nats_204:*:http://localhost:8222/healthz)
        emit_response '' 204
        exit 0
        ;;
    nats_redirect:*:http://localhost:8222/healthz)
        emit_response '' 302
        exit 0
        ;;
    nats_wrong_body:*:http://localhost:8222/healthz)
        emit_response 'not-ok' 200
        exit 0
        ;;
    prometheus_wrong_body:*:http://localhost:9090/-/healthy)
        emit_response 'not-prometheus' 200
        exit 0
        ;;
    hermes_false_fast:false:http://localhost:8085/health|hermes_false_post:true:http://localhost:8085/health)
        emit_response '{"status":"ok","nats_connected":false}' 200
        exit 0
        ;;
    hermes_missing_fast:false:http://localhost:8085/health|hermes_missing_post:true:http://localhost:8085/health)
        emit_response '{"status":"ok"}' 200
        exit 0
        ;;
    hermes_malformed_fast:false:http://localhost:8085/health|hermes_malformed_post:true:http://localhost:8085/health)
        emit_response '{"status":"ok","nats_connected":' 200
        exit 0
        ;;
    argus_arbitrary_fast:false:http://localhost:9100/metrics|argus_arbitrary_post:true:http://localhost:9100/metrics)
        emit_response 'healthy' 200
        exit 0
        ;;
    argus_malformed_fast:false:http://localhost:9100/metrics|argus_malformed_post:true:http://localhost:9100/metrics)
        emit_response 'hi_agamemnon_health not-a-number' 200
        exit 0
        ;;
    argus_wrong_fast:false:http://localhost:9100/metrics|argus_wrong_post:true:http://localhost:9100/metrics)
        emit_response 'hi_agamemnon_health 0' 200
        exit 0
        ;;
esac

case "$url" in
    http://localhost:8080/v1/health|http://localhost:8081/v1/health)
        emit_response '{"status":"ok"}' 200
        ;;
    http://localhost:8085/health)
        emit_response '{"status":"ok","nats_connected":true}' 200
        ;;
    http://localhost:8222/healthz)
        emit_response '{"status":"ok"}' 200
        ;;
    http://localhost:9090/-/healthy)
        emit_response 'Prometheus Server is Healthy.' 200
        ;;
    http://localhost:3001/api/health)
        emit_response '{"database":"ok"}' 200
        ;;
    http://localhost:9100/metrics)
        emit_response 'hi_agamemnon_health 1' 200
        ;;
    http://localhost:8222/varz)
        emit_response '{"connections":4,"in_msgs":2}' 200
        ;;
    http://localhost:9090/-/reload) ;;
    *) exit 22 ;;
esac
SH

chmod +x "$FAKE_BIN"/*

run_start_stack() {
    if [ -n "${RUNTIME_DIR_OVERRIDE:-}" ]; then
        CURRENT_RUNTIME_DIR="$RUNTIME_DIR_OVERRIDE"
    elif ! CURRENT_RUNTIME_DIR="$(make_fixture_directory "$TMP/runtime.")"; then
        printf '%s\n' 'ERROR: could not create start-stack runtime fixture' >&2
        exit 1
    fi
    : > "$PODMAN_LOG"
    : > "$CURL_LOG"
    rm -f "$STACK_STARTED"
    find "$PODMAN_STATE_DIR" -type f -delete
    printf '%s\n' 'container-victim-bytes' > "$CONTAINER_VICTIM"
    CONTAINER_VICTIM_ID="$(file_identity "$CONTAINER_VICTIM")"
    printf '%s\n' 'targets: ["argus-exporter:9100"]' > "$EXISTING_PROMETHEUS_CONFIG"
    chmod 644 "$EXISTING_PROMETHEUS_CONFIG"
    reset_protected_files
    set +e
    STACK_OUTPUT="$(
        cd "${START_STACK_CWD:-$ROOT}" || exit 98
        PODMAN_LOG="$PODMAN_LOG" \
        CURL_LOG="$CURL_LOG" \
        STACK_STARTED="$STACK_STARTED" \
        ODYSSEUS_E2E_RUNTIME_DIR="${RUNTIME_ENV_VALUE-$CURRENT_RUNTIME_DIR}" \
        TMPDIR="${START_STACK_TMPDIR:-${TMPDIR:-/tmp}}" \
        HEALTH_SCENARIO="${HEALTH_SCENARIO:-healthy}" \
        CONTAINER_SCENARIO="${CONTAINER_SCENARIO:-running}" \
        CONTAINER_EXISTENCE_SCENARIO="${CONTAINER_EXISTENCE_SCENARIO:-all}" \
        CONTAINER_METADATA_SCENARIO="${CONTAINER_METADATA_SCENARIO:-valid}" \
        PODMAN_STATE_DIR="$PODMAN_STATE_DIR" \
        PODMAN_VICTIM="$CONTAINER_VICTIM" \
        EXISTING_PROMETHEUS_CONFIG="$EXISTING_PROMETHEUS_CONFIG" \
        EXPECTED_PROJECT_ROOT="$FIXTURE" \
        EXPECTED_ARGUS_DIR="$EXPECTED_ARGUS_ROOT" \
        RUNTIME_RACE="${RUNTIME_RACE:-}" \
        RUNTIME_CONFIG="$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" \
        RUNTIME_DIRECTORY="$CURRENT_RUNTIME_DIR" \
        RUNTIME_ANCESTOR="${RUNTIME_ANCESTOR:-}" \
        RUNTIME_MOVED_ANCESTOR="${RUNTIME_MOVED_ANCESTOR:-}" \
        RUNTIME_REPLACEMENT_ANCESTOR="${RUNTIME_REPLACEMENT_ANCESTOR:-}" \
        RUNTIME_VICTIM="${RUNTIME_VICTIM:-}" \
        RUNTIME_VICTIM_DIRECTORY="${RUNTIME_VICTIM_DIRECTORY:-}" \
        RUNTIME_RACE_MARKER="${RUNTIME_RACE_MARKER:-}" \
        HTTP_PROXY="${START_STACK_HTTP_PROXY-${HTTP_PROXY-}}" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
            /bin/bash "$FIXTURE/e2e/start-stack.sh" 2>&1
    )"
    STACK_STATUS=$?
    set -e
}

file_identity() {
    python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev}:{s.st_ino}")' "$1"
}

runtime_artifacts_have_safe_modes() {
    python3 - "$1" <<'PY'
import os
import stat
import sys

runtime_dir = sys.argv[1]
directory = os.stat(runtime_dir, follow_symlinks=False)
config = os.stat(os.path.join(runtime_dir, "prometheus.runtime.yml"), follow_symlinks=False)
raise SystemExit(0 if (
    directory.st_uid == os.getuid()
    and stat.S_ISDIR(directory.st_mode)
    and stat.S_IMODE(directory.st_mode) & 0o077 == 0
    and config.st_uid == os.getuid()
    and stat.S_ISREG(config.st_mode)
    # The owner-private directory prevents host-side discovery.  Prometheus
    # runs as a non-owner identity in the container, so the read-only bind
    # source itself must remain readable after user-namespace mapping.
    and stat.S_IMODE(config.st_mode) == 0o644
    and config.st_nlink == 1
) else 1)
PY
}

info "partial pre-existing service health never becomes an already-running stack"
CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_EXISTENCE_SCENARIO
resolved_config="$(find "$CURRENT_RUNTIME_DIR" -name 'prometheus.resolved.*.yml' -type f -print -quit)"
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
    && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && protected_files_are_unchanged \
    && [ -f "$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" ] \
    && grep -Fq 'argus-exporter:9100' "$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" \
    && [ -n "$resolved_config" ] \
    && grep -Fq '10.0.0.9:9100' "$resolved_config" \
    && grep -Fq -- "-v $resolved_config:/etc/prometheus/prometheus.yml:ro" "$PODMAN_LOG" \
    && runtime_artifacts_have_safe_modes "$CURRENT_RUNTIME_DIR" \
    && ! find "$CURRENT_RUNTIME_DIR" -name '.prometheus.*' -print -quit | grep -q . \
    && grep -Fq "PROMETHEUS_CONFIG=$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" "$PODMAN_LOG" \
    && grep -Fqx 'PODMAN_COMPOSE_NAME_SEPARATOR_COMPAT=true' "$PODMAN_LOG"; then
    pass "a partial stack is brought to the requested complete state"
else
    fail "Agamemnon-only health incorrectly skipped complete bring-up"
fi

info "post-start health failure cannot produce readiness"
CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO=post_failure \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_EXISTENCE_SCENARIO
if [ "$STACK_STATUS" -ne 0 ] \
    && grep -q 'Hermes: FAIL' <<<"$STACK_OUTPUT" \
    && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT"; then
    pass "a failed required endpoint produces a non-zero terminal result"
else
    fail "a failed required endpoint still produced stack readiness"
fi

info "container identity/state is part of readiness"
CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO=healthy \
    CONTAINER_SCENARIO=stopped run_start_stack
unset CONTAINER_EXISTENCE_SCENARIO
if [ "$STACK_STATUS" -ne 0 ] \
    && grep -q 'odysseus-hermes-1: FAIL' <<<"$STACK_OUTPUT" \
    && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT"; then
    pass "a stopped required container cannot be mistaken for the selected stack"
else
    fail "endpoint-only health hid a stopped or foreign container state"
fi

info "only a complete healthy stack takes the fast path"
HEALTH_SCENARIO=healthy CONTAINER_SCENARIO=running run_start_stack
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && ! grep -q '^compose ' "$PODMAN_LOG" \
    && protected_files_are_unchanged \
    && [ ! -e "$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" ] \
    && [ ! -L "$CURRENT_RUNTIME_DIR/prometheus.runtime.yml" ]; then
    pass "complete endpoint and container evidence permits the fast path"
else
    fail "complete stack evidence did not produce the safe fast path"
fi
if awk '
function positive(value) { return value ~ /^[1-9][0-9]*$/ }
{
    url = 0
    connect = ""
    total = ""
    for (field = 1; field <= NF; field++) {
        if ($field ~ /^https?:\/\//) url = 1
        if ($field == "--connect-timeout") connect = $(field + 1)
        if ($field == "--max-time") total = $(field + 1)
    }
    if (url) {
        seen++
        if (!positive(connect) || !positive(total) \
                || connect > total || total > 15) bad = 1
    }
}
END { exit !(seen > 0 && bad == 0) }
' "$CURL_LOG"; then
    pass "every start-stack HTTP boundary has a bounded connect and total time"
else
    fail "start-stack used an unbounded or over-budget HTTP boundary"
fi

info "stack readiness requires exact status and endpoint body contracts"
for readiness_scenario in \
    nats_204 nats_redirect nats_wrong_body prometheus_wrong_body; do
    HEALTH_SCENARIO="$readiness_scenario" CONTAINER_SCENARIO=running \
        run_start_stack
    if [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
        && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT"; then
        pass "$readiness_scenario cannot become stack readiness"
    else
        fail "$readiness_scenario became stack readiness"
    fi
done

readiness_body_scenarios=(
    hermes_false
    hermes_missing
    hermes_malformed
    argus_arbitrary
    argus_malformed
    argus_wrong
)
readiness_body_labels=(
    'Hermes nats_connected=false'
    'Hermes missing nats_connected'
    'Hermes malformed JSON'
    'Argus arbitrary body'
    'Argus malformed metric'
    'Argus wrong metric value'
)
readiness_failure_labels=(
    'Hermes: FAIL'
    'Hermes: FAIL'
    'Hermes: FAIL'
    'Argus exporter: FAIL'
    'Argus exporter: FAIL'
    'Argus exporter: FAIL'
)

info "fast-path readiness rejects invalid Hermes and Argus bodies"
for ((readiness_index = 0;
      readiness_index < ${#readiness_body_scenarios[@]};
      readiness_index++)); do
    readiness_scenario="${readiness_body_scenarios[$readiness_index]}_fast"
    HEALTH_SCENARIO="$readiness_scenario" CONTAINER_SCENARIO=running \
        run_start_stack
    if [ "$STACK_STATUS" -eq 0 ] \
        && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
        && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
        && grep -q 'Stack ready' <<<"$STACK_OUTPUT"; then
        pass "${readiness_body_labels[$readiness_index]} cannot take the fast path"
    else
        fail "${readiness_body_labels[$readiness_index]} became fast-path readiness"
    fi
done

info "terminal readiness rejects invalid Hermes and Argus bodies"
for ((readiness_index = 0;
      readiness_index < ${#readiness_body_scenarios[@]};
      readiness_index++)); do
    readiness_scenario="${readiness_body_scenarios[$readiness_index]}_post"
    CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO="$readiness_scenario" \
        CONTAINER_SCENARIO=running run_start_stack
    if [ "$STACK_STATUS" -ne 0 ] \
        && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
        && grep -Fq "${readiness_failure_labels[$readiness_index]}" \
            <<<"$STACK_OUTPUT" \
        && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT"; then
        pass "${readiness_body_labels[$readiness_index]} cannot become terminal readiness"
    else
        fail "${readiness_body_labels[$readiness_index]} became terminal readiness"
    fi
done

info "provider-native labels and matching proxy environment are accepted"
START_STACK_HTTP_PROXY=http://proxy.fixture.invalid:3128 \
    CONTAINER_METADATA_SCENARIO=docker_only_labels HEALTH_SCENARIO=healthy \
    CONTAINER_SCENARIO=running run_start_stack
unset START_STACK_HTTP_PROXY CONTAINER_METADATA_SCENARIO
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && ! grep -Eq '^(compose|run|rm) ' "$PODMAN_LOG" \
    && protected_files_are_unchanged; then
    pass "provider labels and a documented Podman proxy bind the selected stack"
else
    fail "provider labels or matching Podman proxy environment were rejected"
fi

info "fast-path ownership is revalidated at the terminal boundary"
CONTAINER_METADATA_SCENARIO=fast_path_aba HEALTH_SCENARIO=healthy \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_METADATA_SCENARIO
if [ "$STACK_STATUS" -ne 0 ] \
    && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && ! grep -Eq '^(compose|run|rm) ' "$PODMAN_LOG" \
    && [ "$(cat "$CONTAINER_VICTIM")" = container-victim-bytes ] \
    && [ "$(file_identity "$CONTAINER_VICTIM")" = "$CONTAINER_VICTIM_ID" ]; then
    pass "a fast-path name replacement cannot become terminal success"
else
    fail "fast-path readiness trusted a stale container binding"
fi

info "runtime config publication rejects existing destinations before compose"
for destination_kind in symlink directory regular; do
    runtime_dir="$(mktemp -d "$TMP/rejected-runtime.XXXXXX")"
    victim="$TMP/${destination_kind}-victim"
    printf '%s\n' 'do-not-overwrite' > "$victim"
    case "$destination_kind" in
        symlink) ln -s "$victim" "$runtime_dir/prometheus.runtime.yml" ;;
        directory) mkdir "$runtime_dir/prometheus.runtime.yml" ;;
        regular) printf '%s\n' 'operator-owned-runtime' > "$runtime_dir/prometheus.runtime.yml" ;;
    esac
    : > "$PODMAN_LOG"
    rm -f "$STACK_STARTED"
    find "$PODMAN_STATE_DIR" -type f -delete
    printf '%s\n' 'container-victim-bytes' > "$CONTAINER_VICTIM"
    reset_protected_files
    set +e
    STACK_OUTPUT="$(
        PODMAN_LOG="$PODMAN_LOG" \
        STACK_STARTED="$STACK_STARTED" \
        PODMAN_STATE_DIR="$PODMAN_STATE_DIR" \
        PODMAN_VICTIM="$CONTAINER_VICTIM" \
        EXISTING_PROMETHEUS_CONFIG="$EXISTING_PROMETHEUS_CONFIG" \
        EXPECTED_PROJECT_ROOT="$FIXTURE" \
        EXPECTED_ARGUS_DIR="$EXPECTED_ARGUS_ROOT" \
        ODYSSEUS_E2E_RUNTIME_DIR="$runtime_dir" \
        CONTAINER_EXISTENCE_SCENARIO=none \
        HEALTH_SCENARIO=partial \
        CONTAINER_SCENARIO=running \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
            /bin/bash "$FIXTURE/e2e/start-stack.sh" 2>&1
    )"
    STACK_STATUS=$?
    set -e
    if [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -q '^compose ' "$PODMAN_LOG" \
        && protected_files_are_unchanged \
        && rejected_destination_is_unchanged "$destination_kind" "$runtime_dir" "$victim"; then
        pass "$destination_kind runtime config destination is rejected without mutation"
    else
        fail "$destination_kind runtime config destination was accepted or mutated"
    fi
done

info "caller-selected runtime directories must already be owner-private"
runtime_dir="$(mktemp -d "$TMP/public-runtime.XXXXXX")"
chmod 755 "$runtime_dir"
RUNTIME_DIR_OVERRIDE="$runtime_dir" CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset RUNTIME_DIR_OVERRIDE CONTAINER_EXISTENCE_SCENARIO
if [ "$STACK_STATUS" -ne 0 ] \
    && ! grep -q '^compose ' "$PODMAN_LOG" \
    && [ ! -e "$runtime_dir/prometheus.runtime.yml" ] \
    && protected_files_are_unchanged; then
    pass "non-private runtime directory is rejected before stack effects"
else
    fail "non-private runtime directory was accepted or mutated"
fi

info "relative runtime paths are canonicalized before Compose sees them"
relative_root="$TMP/relative-runtime-root"
relative_runtime="$relative_root/runtime"
relative_caller="$relative_root/caller"
mkdir -p "$relative_runtime" "$relative_caller"
chmod 700 "$relative_runtime"
relative_runtime="$(cd "$relative_runtime" && pwd -P)"
relative_caller="$(cd "$relative_caller" && pwd -P)"
RUNTIME_DIR_OVERRIDE=../runtime START_STACK_CWD="$relative_caller" \
    CONTAINER_EXISTENCE_SCENARIO=none HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset RUNTIME_DIR_OVERRIDE START_STACK_CWD CONTAINER_EXISTENCE_SCENARIO
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -Fq "PROMETHEUS_CONFIG=$relative_runtime/prometheus.runtime.yml" \
        "$PODMAN_LOG" \
    && [ -f "$relative_runtime/prometheus.runtime.yml" ] \
    && protected_files_are_unchanged; then
    pass "relative caller input becomes one absolute runtime authority"
else
    fail "relative runtime authority remained dependent on process cwd"
fi

info "relative TMPDIR output is canonicalized before Compose sees it"
default_relative_root="$TMP/default-relative-runtime"
default_relative_caller="$default_relative_root/caller"
mkdir -p "$default_relative_caller/tmp"
default_relative_caller="$(cd "$default_relative_caller" && pwd -P)"
RUNTIME_ENV_VALUE="" START_STACK_CWD="$default_relative_caller" \
    START_STACK_TMPDIR=tmp CONTAINER_EXISTENCE_SCENARIO=none \
    HEALTH_SCENARIO=partial CONTAINER_SCENARIO=running run_start_stack
unset RUNTIME_ENV_VALUE START_STACK_CWD START_STACK_TMPDIR \
    CONTAINER_EXISTENCE_SCENARIO
default_runtime_prefix="^PROMETHEUS_CONFIG=${default_relative_caller}/tmp/"
default_runtime_pattern="${default_runtime_prefix}homeric-intelligence-e2e"
default_runtime_pattern="${default_runtime_pattern}\.[^/]+/prometheus\.runtime\.yml$"
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -Eq "$default_runtime_pattern" "$PODMAN_LOG" \
    && protected_files_are_unchanged; then
    pass "default runtime creation publishes one absolute authority"
else
    fail "relative TMPDIR left runtime authority dependent on process cwd"
fi

info "runtime config update is bound against link and ancestor replacement"
for race_kind in hardlink symlink ancestor; do
    runtime_dir="$(mktemp -d "$TMP/${race_kind}-runtime.XXXXXX")"
    victim="$TMP/${race_kind}-runtime-victim"
    runtime_ancestor=""
    moved_ancestor=""
    replacement_ancestor=""
    marker="$TMP/${race_kind}-runtime-race"
    if [ "$race_kind" = ancestor ]; then
        runtime_ancestor="$TMP/ancestor-active"
        moved_ancestor="$TMP/ancestor-moved"
        replacement_ancestor="$TMP/ancestor-replacement"
        mkdir -p "$runtime_ancestor/runtime" "$replacement_ancestor/runtime"
        chmod 700 "$runtime_ancestor/runtime" "$replacement_ancestor/runtime"
        runtime_dir="$runtime_ancestor/runtime"
        victim="$replacement_ancestor/runtime/prometheus.runtime.yml"
    fi
    printf '%s\n' "${race_kind}-victim-bytes" > "$victim"
    chmod 600 "$victim"
    victim_identity="$(file_identity "$victim")"

    RUNTIME_DIR_OVERRIDE="$runtime_dir" \
    RUNTIME_RACE="$race_kind" \
    RUNTIME_VICTIM="$victim" \
    RUNTIME_ANCESTOR="$runtime_ancestor" \
    RUNTIME_MOVED_ANCESTOR="$moved_ancestor" \
    RUNTIME_REPLACEMENT_ANCESTOR="$replacement_ancestor" \
    RUNTIME_RACE_MARKER="$marker" \
    CONTAINER_EXISTENCE_SCENARIO=none \
    HEALTH_SCENARIO=partial CONTAINER_SCENARIO=running run_start_stack
    unset RUNTIME_DIR_OVERRIDE RUNTIME_RACE RUNTIME_VICTIM \
        RUNTIME_ANCESTOR RUNTIME_MOVED_ANCESTOR RUNTIME_REPLACEMENT_ANCESTOR \
        RUNTIME_RACE_MARKER \
        CONTAINER_EXISTENCE_SCENARIO

    if [ "$race_kind" = ancestor ]; then
        victim="$runtime_ancestor/runtime/prometheus.runtime.yml"
    fi

    if [ -e "$marker" ] \
        && [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
        && [ "$(cat "$victim")" = "${race_kind}-victim-bytes" ] \
        && [ "$(file_identity "$victim")" = "$victim_identity" ]; then
        pass "$race_kind replacement is rejected with victim bytes and inode preserved"
    else
        fail "$race_kind replacement reached publication or changed its victim"
    fi
done

container_victim_is_unchanged() {
    [ "$(cat "$CONTAINER_VICTIM")" = container-victim-bytes ] \
        && [ "$(file_identity "$CONTAINER_VICTIM")" = "$CONTAINER_VICTIM_ID" ]
}

info "foreign ownership cannot satisfy an otherwise healthy fast path"
for label_scenario in foreign_label foreign_podman_label; do
    CONTAINER_METADATA_SCENARIO="$label_scenario" HEALTH_SCENARIO=healthy \
        CONTAINER_SCENARIO=running run_start_stack
    unset CONTAINER_METADATA_SCENARIO
    if [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
        && ! grep -Eq '^(compose|run|rm) ' "$PODMAN_LOG" \
        && container_victim_is_unchanged; then
        pass "$label_scenario ownership is rejected before any stack mutation"
    else
        fail "$label_scenario ownership reached fast-path success or stack mutation"
    fi
done

info "partial owned state does not require images that Compose has not built yet"
CONTAINER_EXISTENCE_SCENARIO=partial_assets HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_EXISTENCE_SCENARIO
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
    && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
    && ! grep -q -- '--replace' "$PODMAN_LOG" \
    && container_victim_is_unchanged; then
    pass "missing images for absent containers are resolved after Compose"
else
    fail "partial state required absent-container images before Compose"
fi

info "Compose cannot replace a pre-bound partial-stack occupant"
CONTAINER_EXISTENCE_SCENARIO=partial_assets \
    CONTAINER_METADATA_SCENARIO=compose_aba HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_EXISTENCE_SCENARIO CONTAINER_METADATA_SCENARIO
if [ "$STACK_STATUS" -ne 0 ] \
    && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
    && ! grep -Eq '^(run|rm) ' "$PODMAN_LOG" \
    && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
    && container_victim_is_unchanged; then
    pass "post-Compose binding retains the pre-existing immutable receipt"
else
    fail "post-Compose binding adopted a same-contract replacement occupant"
fi

info "foreign identity, network, and mount records stop before compose"
for metadata_scenario in foreign_image foreign_name foreign_network \
    foreign_network_membership foreign_mount; do
    CONTAINER_METADATA_SCENARIO="$metadata_scenario" HEALTH_SCENARIO=partial \
        CONTAINER_SCENARIO=running run_start_stack
    unset CONTAINER_METADATA_SCENARIO
    if [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -Eq '^(compose|run|rm) ' "$PODMAN_LOG" \
        && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
        && container_victim_is_unchanged; then
        pass "$metadata_scenario container record is rejected without mutation"
    else
        fail "$metadata_scenario container record reached a destructive effect"
    fi
done

info "foreign runtime contracts stop before compose"
for metadata_scenario in foreign_config_env foreign_config_cmd \
    foreign_config_entrypoint foreign_ports foreign_resources foreign_restart \
    foreign_health missing_hello_agamemnon_url; do
    CONTAINER_METADATA_SCENARIO="$metadata_scenario" HEALTH_SCENARIO=healthy \
        CONTAINER_SCENARIO=running run_start_stack
    unset CONTAINER_METADATA_SCENARIO
    if [ "$STACK_STATUS" -ne 0 ] \
        && ! grep -Eq '^(compose|run|rm) ' "$PODMAN_LOG" \
        && ! grep -q 'Stack already running' <<<"$STACK_OUTPUT" \
        && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
        && container_victim_is_unchanged; then
        pass "$metadata_scenario runtime contract is rejected without mutation"
    else
        fail "$metadata_scenario runtime contract reached success or mutation"
    fi
done

info "name-to-ID replacement races preserve the new occupant"
CONTAINER_METADATA_SCENARIO=aba HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_METADATA_SCENARIO
foreign_id="$(printf '%064x' 255)"
if [ "$STACK_STATUS" -ne 0 ] \
    && ! grep -Fq "rm -f $foreign_id" "$PODMAN_LOG" \
    && ! grep -q -- '--replace' "$PODMAN_LOG" \
    && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
    && container_victim_is_unchanged; then
    pass "a replacement occupant is never removed by mutable name"
else
    fail "name-to-ID race deleted or replaced the foreign occupant"
fi

info "Prometheus storage-volume replacement races stop before retirement"
CONTAINER_METADATA_SCENARIO=volume_aba HEALTH_SCENARIO=partial \
    CONTAINER_SCENARIO=running run_start_stack
unset CONTAINER_METADATA_SCENARIO
prometheus_id="$(printf '%064d' 5)"
if [ "$STACK_STATUS" -ne 0 ] \
    && [ -f "$PODMAN_STATE_DIR/volume-inspect" ] \
    && [ "$(cat "$PODMAN_STATE_DIR/volume-inspect")" -ge 2 ] \
    && ! grep -Fq "rm -f $prometheus_id" "$PODMAN_LOG" \
    && ! grep -q 'Stack ready' <<<"$STACK_OUTPUT" \
    && container_victim_is_unchanged; then
    pass "a replaced Prometheus data volume is not retired or reattached"
else
    fail "Prometheus replacement trusted a stale storage-volume binding"
fi

info "valid owned partial state retires only bound IDs without name replacement"
HEALTH_SCENARIO=partial CONTAINER_SCENARIO=running run_start_stack
owned_retires=true
for owned_index in 1 3 4 7 8; do
    owned_id="$(printf '%064d' "$((owned_index + 1))")"
    grep -Fqx "rm -f $owned_id" "$PODMAN_LOG" || owned_retires=false
done
if [ "$STACK_STATUS" -eq 0 ] \
    && grep -q '^compose .* up -d --no-recreate$' "$PODMAN_LOG" \
    && [ "$(grep -c '^rm -f ' "$PODMAN_LOG")" -eq 5 ] \
    && [ "$owned_retires" = true ] \
    && ! grep -q -- '--replace' "$PODMAN_LOG" \
    && grep -q -- '--network-alias prometheus' "$PODMAN_LOG" \
    && grep -Fq -- '-v odysseus-prometheus-data:/prometheus' "$PODMAN_LOG" \
    && grep -q -- '--cpus 2 --cpu-shares 512 --memory 2g --memory-reservation 256m' \
        "$PODMAN_LOG" \
    && grep -q -- '--config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle' \
        "$PODMAN_LOG" \
    && grep -Fq "PROMETHEUS_CONFIG=$EXISTING_PROMETHEUS_CONFIG" "$PODMAN_LOG" \
    && grep -Fq 'argus-exporter:9100' "$EXISTING_PROMETHEUS_CONFIG" \
    && container_victim_is_unchanged; then
    pass "valid owned containers are replaced by immutable identity only"
else
    fail "valid owned state used mutable-name replacement or wrong identities"
fi

summary
exit_code
