#!/usr/bin/env bash
# HomericIntelligence E2E Stack Launcher
# Handles podman rootless DNS issues by discovering container IPs
# and restarting NATS-dependent services with direct IP addresses.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ODYSSEUS_ROOT/docker-compose.e2e.yml"

# Resolve symlink paths for podman (can't follow symlinks as build contexts)
PROJECT_ROOT="$ODYSSEUS_ROOT"
HERMES_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/ProjectHermes")"
ARGUS_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/ProjectArgus")"
MYRMIDONS_DIR="$(readlink -f "$ODYSSEUS_ROOT/provisioning/Myrmidons")"
PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"

# Write .env for compose variable substitution
cat > "$ODYSSEUS_ROOT/.env" <<EOF
PROJECT_ROOT=$PROJECT_ROOT
HERMES_DIR=$HERMES_DIR
ARGUS_DIR=$ARGUS_DIR
MYRMIDONS_DIR=$MYRMIDONS_DIR
PODMAN_SOCK=$PODMAN_SOCK
EOF

echo "╔══════════════════════════════════════════════╗"
echo "║  Starting HomericIntelligence E2E Stack      ║"
echo "╚══════════════════════════════════════════════╝"

# If the stack is already running (agamemnon healthy), skip bring-up
if curl -sf http://localhost:8080/v1/health >/dev/null 2>&1; then
  echo "Stack already running — skipping bring-up."
  exit 0
fi

get_ip() {
  podman inspect "$1" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
nets=d[0]['NetworkSettings']['Networks']
print(list(nets.values())[0]['IPAddress'])"
}

# ── Step 1: Generate initial Prometheus config (placeholder — patched after exporter IP known) ──
cp "$ODYSSEUS_ROOT/e2e/prometheus.yml" "$ODYSSEUS_ROOT/e2e/prometheus.runtime.yml"

# ── Step 2: Bring up everything via compose ──
echo "Starting all services via compose..."
podman compose -f "$COMPOSE_FILE" up -d 2>&1 | tail -10
echo "Waiting 10s for services to initialize..."
sleep 10

# ── Step 2: Get NATS IP (stable — NATS was not restarted) ──
NATS_IP=$(get_ip odysseus-nats-1)
NESTOR_IP=$(get_ip odysseus-nestor-1)
echo "NATS=$NATS_IP  Nestor=$NESTOR_IP"

# ── Step 3: Restart NATS-dependent services with direct IPs ──
echo "Restarting services with direct NATS IP (podman DNS workaround)..."

# Agamemnon (C++)
podman run -d --replace --name odysseus-agamemnon-1 \
  --network odysseus_homeric-mesh \
  -p 8080:8080 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  odysseus-agamemnon:latest 2>&1 | tail -1

# Hermes (Python)
podman run -d --replace --name odysseus-hermes-1 \
  --network odysseus_homeric-mesh \
  -p 8085:8085 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  -e "HERMES_PORT=8085" \
  odysseus-hermes:latest 2>&1 | tail -1

# Hello Myrmidon (C++)
podman run -d --replace --name odysseus-hello-myrmidon-1 \
  --network odysseus_homeric-mesh \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  --restart on-failure \
  odysseus-hello-myrmidon:latest 2>&1 | tail -1

# Wait for Agamemnon to start
sleep 5
AGAMEMNON_IP=$(get_ip odysseus-agamemnon-1)
echo "Agamemnon=$AGAMEMNON_IP"

# Argus Exporter (Python — needs Agamemnon + Nestor + NATS IPs)
podman run -d --replace --name odysseus-argus-exporter-1 \
  --network odysseus_homeric-mesh \
  -p 9100:9100 \
  -e "AGAMEMNON_URL=http://${AGAMEMNON_IP}:8080" \
  -e "NESTOR_URL=http://${NESTOR_IP}:8081" \
  -e "NATS_URL=http://${NATS_IP}:8222" \
  odysseus-argus-exporter:latest 2>&1 | tail -1

# ── Step 4: Patch Prometheus config with resolved argus-exporter IP ──
sleep 3
ARGUS_IP=$(get_ip odysseus-argus-exporter-1)
if [ -n "$ARGUS_IP" ]; then
  sed "s/argus-exporter:9100/${ARGUS_IP}:9100/g" \
    "$ODYSSEUS_ROOT/e2e/prometheus.yml" \
    > "$ODYSSEUS_ROOT/e2e/prometheus.runtime.yml"
  # Prometheus re-reads the bind-mounted file on /-/reload (lifecycle enabled)
  curl -sf -X POST http://localhost:9090/-/reload 2>/dev/null \
    && echo "Prometheus config reloaded: argus-exporter=${ARGUS_IP}" \
    || echo "Prometheus reload skipped (not ready yet)"
fi

# ── Step 5: Wait and verify ──
echo "Waiting 10s for connections..."
sleep 10

echo ""
echo "=== Service Status ==="
podman ps --format '{{.Names}} {{.Status}}' | grep odysseus | sort

echo ""
echo "=== Health Checks ==="
curl -sf http://localhost:8080/v1/health && echo " (Agamemnon)" || echo "Agamemnon: FAIL"
curl -sf http://localhost:8081/v1/health && echo " (Nestor)" || echo "Nestor: FAIL"
curl -sf http://localhost:8085/health && echo " (Hermes)" || echo "Hermes: FAIL"
curl -sf http://localhost:8222/healthz > /dev/null && echo "NATS: OK" || echo "NATS: FAIL"

echo ""
echo "=== NATS Connections ==="
curl -sf http://localhost:8222/varz | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'  Connections: {d[\"connections\"]}, Messages in: {d[\"in_msgs\"]}')" 2>/dev/null

echo ""
echo "Stack ready. Run: just e2e-test"
