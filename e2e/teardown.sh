#!/usr/bin/env bash
set -uo pipefail

STACK_PROJECT=odysseus
STACK_NETWORK=odysseus_homeric-mesh

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
BOUND_CONTAINER_IDS=()
BOUND_CONTAINER_RECEIPTS=()
BOUND_NETWORK_ID=""
BOUND_NETWORK_RECEIPT=""

failures=0
record_failure() {
  printf 'ERROR: %s\n' "$1" >&2
  failures=$((failures + 1))
}

echo "Tearing down HomericIntelligence E2E stack..."

runtime_engine=""
if command -v podman >/dev/null 2>&1; then
  runtime_engine=podman
elif command -v docker >/dev/null 2>&1; then
  runtime_engine=docker
else
  record_failure "no container runtime is available"
fi

probe_container() {
  local target="$1" probe_status
  if [ "$runtime_engine" = podman ]; then
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

probe_network() {
  local target="$1" probe_status
  if [ "$runtime_engine" = podman ]; then
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

bind_owned_container() {
  local target="$1" expected_name="$2" expected_service="$3"
  local required_id="${4:-}" format receipt
  local container_id actual_name docker_project docker_service
  local podman_project podman_service extra ownership_count=0
  format='{{.Id}}|{{.Name}}|{{if index .Config.Labels "com.docker.compose.project"}}{{index .Config.Labels "com.docker.compose.project"}}{{end}}|{{if index .Config.Labels "com.docker.compose.service"}}{{index .Config.Labels "com.docker.compose.service"}}{{end}}|{{if index .Config.Labels "io.podman.compose.project"}}{{index .Config.Labels "io.podman.compose.project"}}{{end}}|{{if index .Config.Labels "io.podman.compose.service"}}{{index .Config.Labels "io.podman.compose.service"}}{{end}}'
  if ! receipt="$("$runtime_engine" inspect --format "$format" "$target" 2>/dev/null)" \
      || [[ "$receipt" == *$'\n'* ]]; then
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

bind_owned_network() {
  local target="$1" required_id="${2:-}" format receipt
  local network_id actual_name docker_project docker_network
  local podman_project podman_network extra ownership_count=0
  if [ "$runtime_engine" = podman ]; then
    format='{{.ID}}|{{.Name}}|{{if index .Labels "com.docker.compose.project"}}{{index .Labels "com.docker.compose.project"}}{{end}}|{{if index .Labels "com.docker.compose.network"}}{{index .Labels "com.docker.compose.network"}}{{end}}|{{if index .Labels "io.podman.compose.project"}}{{index .Labels "io.podman.compose.project"}}{{end}}|{{if index .Labels "io.podman.compose.network"}}{{index .Labels "io.podman.compose.network"}}{{end}}'
  else
    format='{{.Id}}|{{.Name}}|{{if index .Labels "com.docker.compose.project"}}{{index .Labels "com.docker.compose.project"}}{{end}}|{{if index .Labels "com.docker.compose.network"}}{{index .Labels "com.docker.compose.network"}}{{end}}|{{if index .Labels "io.podman.compose.project"}}{{index .Labels "io.podman.compose.project"}}{{end}}|{{if index .Labels "io.podman.compose.network"}}{{index .Labels "io.podman.compose.network"}}{{end}}'
  fi
  if ! receipt="$("$runtime_engine" network inspect --format "$format" "$target" 2>/dev/null)" \
      || [[ "$receipt" == *$'\n'* ]]; then
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

preflight_status=0
if [ -n "$runtime_engine" ]; then
  for ((container_index = 0; container_index < ${#STACK_CONTAINERS[@]}; container_index++)); do
    container_name="${STACK_CONTAINERS[$container_index]}"
    service_name="${STACK_SERVICES[$container_index]}"
    if probe_container "$container_name"; then
      if receipt="$(bind_owned_container "$container_name" "$container_name" \
          "$service_name")"; then
        BOUND_CONTAINER_RECEIPTS[container_index]="$receipt"
        BOUND_CONTAINER_IDS[container_index]="${receipt%%|*}"
      else
        record_failure "reserved container $container_name is foreign or has no immutable ownership receipt"
        preflight_status=1
      fi
    else
      probe_status=$?
      if [ "$probe_status" -eq 1 ]; then
        BOUND_CONTAINER_RECEIPTS[container_index]=""
        BOUND_CONTAINER_IDS[container_index]=""
      else
        record_failure "could not inspect container $container_name"
        preflight_status=1
      fi
    fi
  done

  if probe_network "$STACK_NETWORK"; then
    if BOUND_NETWORK_RECEIPT="$(bind_owned_network "$STACK_NETWORK")"; then
      BOUND_NETWORK_ID="${BOUND_NETWORK_RECEIPT%%|*}"
    else
      record_failure "reserved network $STACK_NETWORK is foreign or has no immutable ownership receipt"
      preflight_status=1
    fi
  else
    probe_status=$?
    if [ "$probe_status" -ne 1 ]; then
      record_failure "could not inspect network $STACK_NETWORK"
      preflight_status=1
    fi
  fi
else
  record_failure "no container runtime is available for ownership binding"
  preflight_status=1
fi

# Do not run Compose or any direct removal when the read-only preflight cannot
# bind every present reserved object to this exact project.
if [ "$preflight_status" -ne 0 ]; then
  printf 'Teardown refused: %d ownership or probe error(s).\n' "$failures" >&2
  exit 1
fi

# Compose selects resources by mutable labels and can include containers or
# anonymous volumes outside the receipt set above. Remove only the immutable
# IDs bound during preflight; unbound same-project resources are preserved.
for ((container_index = 0; container_index < ${#STACK_CONTAINERS[@]}; container_index++)); do
  container_id="${BOUND_CONTAINER_IDS[$container_index]:-}"
  [ -n "$container_id" ] || continue
  container_name="${STACK_CONTAINERS[$container_index]}"
  service_name="${STACK_SERVICES[$container_index]}"
  if probe_container "$container_id"; then
    if ! receipt="$(bind_owned_container "$container_id" "$container_name" \
        "$service_name" "$container_id")" \
        || [ "$receipt" != "${BOUND_CONTAINER_RECEIPTS[$container_index]}" ]; then
      record_failure "container $container_name changed before direct removal"
      continue
    fi
    if ! "$runtime_engine" rm -f "$container_id"; then
      record_failure "could not remove container $container_name"
      continue
    fi
    if probe_container "$container_id"; then
      record_failure "container $container_name remains after teardown"
    else
      probe_status=$?
      [ "$probe_status" -eq 1 ] \
        || record_failure "could not verify cleanup for container $container_name"
    fi
  else
    probe_status=$?
    [ "$probe_status" -eq 1 ] \
      || record_failure "could not inspect bound container $container_name"
  fi
done

for container_name in "${STACK_CONTAINERS[@]}"; do
  if probe_container "$container_name"; then
    record_failure "replacement container $container_name appeared and was preserved"
  else
    probe_status=$?
    [ "$probe_status" -eq 1 ] \
      || record_failure "could not verify the reserved name $container_name"
  fi
done

if [ -n "$BOUND_NETWORK_ID" ]; then
  if probe_network "$BOUND_NETWORK_ID"; then
    if ! receipt="$(bind_owned_network "$BOUND_NETWORK_ID" "$BOUND_NETWORK_ID")" \
        || [ "$receipt" != "$BOUND_NETWORK_RECEIPT" ]; then
      record_failure "network $STACK_NETWORK changed before direct removal"
    elif ! "$runtime_engine" network rm "$BOUND_NETWORK_ID"; then
      record_failure "could not remove network $STACK_NETWORK"
    elif probe_network "$BOUND_NETWORK_ID"; then
      record_failure "network $STACK_NETWORK remains after teardown"
    else
      probe_status=$?
      [ "$probe_status" -eq 1 ] \
        || record_failure "could not verify the network cleanup postcondition"
    fi
  else
    probe_status=$?
    [ "$probe_status" -eq 1 ] \
      || record_failure "could not inspect the bound network $STACK_NETWORK"
  fi
fi

if probe_network "$STACK_NETWORK"; then
  record_failure "replacement network $STACK_NETWORK appeared and was preserved"
else
  probe_status=$?
  [ "$probe_status" -eq 1 ] \
    || record_failure "could not verify the reserved network name"
fi

if [ "$failures" -ne 0 ]; then
  printf 'Teardown incomplete: %d cleanup operation(s) failed.\n' \
    "$failures" >&2
  exit 1
fi

echo "Done."
