#!/usr/bin/env bash
# HomericIntelligence Cross-Host Stack Launcher
#
# Starts the E2E stack on the worker host (epimetheus) with Nestor excluded.
# Nestor runs natively on the control host and connects to NATS over Tailscale.
#
# Required env:
#   CONTROL_HOST_IP  — Tailscale IP of the control host running Nestor (e.g., 100.73.61.56)
#
# Usage:
#   CONTROL_HOST_IP=100.73.61.56 bash e2e/start-crosshost.sh
set -euo pipefail

if [ -z "${CONTROL_HOST_IP:-}" ]; then
  echo "ERROR: CONTROL_HOST_IP must be set to the control host's Tailscale IP" >&2
  echo "  Example: CONTROL_HOST_IP=100.73.61.56 bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
BASE_COMPOSE="$ODYSSEUS_ROOT/docker-compose.e2e.yml"
OVERLAY_COMPOSE="$ODYSSEUS_ROOT/docker-compose.crosshost.yml"

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
CONTROL_HOST_IP=$CONTROL_HOST_IP
EOF

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Starting HomericIntelligence Cross-Host Stack           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Worker host (this machine):                             ║"
echo "║    NATS, Agamemnon, Hermes, Myrmidons, Argus             ║"
echo "║  Control host ($CONTROL_HOST_IP):                        ║"
echo "║    Nestor (native), Odysseus console                     ║"
echo "╚══════════════════════════════════════════════════════════╝"

get_ip() {
  podman inspect "$1" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
nets=d[0]['NetworkSettings']['Networks']
print(list(nets.values())[0]['IPAddress'])"
}

# ── Step 1: Build and start via compose ──
echo ""
echo "Building and starting services..."
podman compose \
  -f "$BASE_COMPOSE" \
  -f "$OVERLAY_COMPOSE" \
  up -d --build 2>&1 | tail -20
echo "Waiting 10s for services to initialize..."
sleep 10

# ── Step 2: Get container IPs for DNS workaround ──
NATS_IP=$(get_ip odysseus-nats-1)
echo "NATS container IP: $NATS_IP"

# ── Step 3: Restart NATS-dependent services with direct IPs ──
echo "Restarting services with direct NATS IP (podman DNS workaround)..."

# Agamemnon
podman run -d --replace --name odysseus-agamemnon-1 \
  --network odysseus_homeric-mesh \
  -p 8080:8080 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  odysseus-agamemnon:latest 2>&1 | tail -1

# Hermes
podman run -d --replace --name odysseus-hermes-1 \
  --network odysseus_homeric-mesh \
  -p 8085:8085 \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  -e "HERMES_PORT=8085" \
  odysseus-hermes:latest 2>&1 | tail -1

# Hello Myrmidon
podman run -d --replace --name odysseus-hello-myrmidon-1 \
  --network odysseus_homeric-mesh \
  -e "NATS_URL=nats://${NATS_IP}:4222" \
  --restart on-failure \
  odysseus-hello-myrmidon:latest 2>&1 | tail -1

# Wait for Agamemnon to start
sleep 5
AGAMEMNON_IP=$(get_ip odysseus-agamemnon-1)
echo "Agamemnon container IP: $AGAMEMNON_IP"

# Argus Exporter (scrapes Nestor on remote control host)
podman run -d --replace --name odysseus-argus-exporter-1 \
  --network odysseus_homeric-mesh \
  -p 19100:9100 \
  -e "AGAMEMNON_URL=http://${AGAMEMNON_IP}:8080" \
  -e "NESTOR_URL=http://${CONTROL_HOST_IP}:8081" \
  -e "NATS_URL=http://${NATS_IP}:8222" \
  odysseus-argus-exporter:latest 2>&1 | tail -1

# NATS-to-Loki bridge (if image exists)
LOKI_IP=$(get_ip odysseus-loki-1 2>/dev/null || echo "")
if podman image exists odysseus-nats-loki-bridge 2>/dev/null; then
  podman run -d --replace --name odysseus-nats-loki-bridge-1 \
    --network odysseus_homeric-mesh \
    -e "NATS_URL=nats://${NATS_IP}:4222" \
    -e "LOKI_URL=http://${LOKI_IP}:3100" \
    --restart on-failure \
    odysseus-nats-loki-bridge:latest 2>&1 | tail -1
  echo "NATS-to-Loki bridge started"
else
  echo "NATS-to-Loki bridge image not found (optional — build Phase 3)"
fi

# ── Step 4: Wait and verify ──
echo ""
echo "Waiting 10s for connections..."
sleep 10

echo ""
echo "=== Service Status ==="
podman ps --format '{{.Names}} {{.Status}}' | grep odysseus | sort

echo ""
echo "=== Health Checks ==="
curl -sf http://localhost:8080/v1/health && echo " (Agamemnon)" || echo "Agamemnon: FAIL"
curl -sf http://localhost:8085/health && echo " (Hermes)" || echo "Hermes: FAIL"
curl -sf http://localhost:8222/healthz > /dev/null && echo "NATS: OK" || echo "NATS: FAIL"
echo ""
echo "Checking remote Nestor at ${CONTROL_HOST_IP}:8081..."
curl -sf "http://${CONTROL_HOST_IP}:8081/v1/health" && echo " (Nestor)" || echo "Nestor: NOT RUNNING (start on control host)"

echo ""
echo "=== NATS Connections ==="
curl -sf http://localhost:8222/varz | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'  Connections: {d[\"connections\"]}, Messages in: {d[\"in_msgs\"]}')" 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Worker host stack ready.                                ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  On control host ($CONTROL_HOST_IP), run:                ║"
echo "║                                                          ║"
echo "║  Console 1 — Start Nestor:                               ║"
echo "║    NATS_URL=nats://$(hostname -I | awk '{print $1}'):4222 \\                         ║"
echo "║    ./build/ProjectNestor/ProjectNestor_server             ║"
echo "║                                                          ║"
echo "║  Console 2 — Apply agents:                               ║"
echo "║    AGAMEMNON_URL=http://$(hostname -I | awk '{print $1}'):8080 \\                    ║"
echo "║    ./scripts/apply.sh                                    ║"
echo "║                                                          ║"
echo "║  Grafana:    http://$(hostname -I | awk '{print $1}'):3001                          ║"
echo "║  Prometheus: http://$(hostname -I | awk '{print $1}'):9090                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
