#!/usr/bin/env bash
# HomericIntelligence Hermes-Hub Topology Launcher
#
# Starts the full E2E stack on hermes (100.73.61.56) with hello-myrmidon excluded,
# then launches the Python hello-myrmidon worker on epimetheus (100.92.173.32) so
# it pulls tasks from NATS on hermes over Tailscale.
#
# Requires:
#   - ssh hermes   →  mvillmow@100.73.61.56  (passwordless)
#   - ssh epimetheus → mvillmow@100.92.173.32 (passwordless)
#   - Odysseus repo cloned at ~/Odysseus on hermes
#   - nats-py installed on epimetheus (verified: 2.14.0)
#
# Usage (from any machine with the SSH aliases configured):
#   bash e2e/start-hermes-hub.sh
set -euo pipefail

HERMES_IP="100.73.61.56"
EPI_IP="100.92.173.32"
HERMES_SSH="hermes"
EPI_SSH="epimetheus"
ODYSSEUS_REMOTE="~/Odysseus"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
die()  { echo -e "  ${RED}✗ FATAL${NC}: $1" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence Hermes-Hub Stack Launcher           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  hermes (${HERMES_IP}):                                  ║"
echo "║    NATS · Agamemnon · Nestor · Hermes bridge             ║"
echo "║    Prometheus · Loki · Grafana · argus-exporter          ║"
echo "║  epimetheus (${EPI_IP}):                                  ║"
echo "║    hello-myrmidon (Python, Tailscale NATS consumer)      ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Step 1: Prerequisites on hermes ─────────────────────────────────────────
info "Step 1: Checking/installing prerequisites on hermes"

ssh "$HERMES_SSH" bash -s <<'REMOTE_DOCTOR'
set -euo pipefail
cd ~/Odysseus
echo "  Running just doctor --role worker --install..."
just doctor --role worker --install 2>&1 | tail -10 || {
  echo "  doctor --install reported issues (see above); continuing..."
}

# Ensure tailscale0 is in the firewalld trusted zone so epimetheus can reach NATS
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if ! firewall-cmd --get-active-zones 2>/dev/null | grep -A1 "trusted" | grep -q "tailscale0"; then
    echo "  Adding tailscale0 to firewalld trusted zone..."
    sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
    sudo firewall-cmd --reload
    echo "  firewalld: tailscale0 now in trusted zone"
  else
    echo "  firewalld: tailscale0 already in trusted zone"
  fi
fi

# Ensure submodules are initialized
git submodule update --init --recursive --quiet
echo "  Submodules OK"
REMOTE_DOCTOR
ok "hermes prerequisites done"

# ── Step 2: Build and start compose stack on hermes ─────────────────────────
info "Step 2: Building and starting E2E stack on hermes (this takes ~3 min on cold cache)"

ssh "$HERMES_SSH" bash -s <<REMOTE_START
set -euo pipefail
cd ~/Odysseus

# Resolve symlinks for podman (can't follow symlinks in build contexts)
PROJECT_ROOT="\$(pwd)"
HERMES_DIR="\$(readlink -f infrastructure/ProjectHermes)"
ARGUS_DIR="\$(readlink -f infrastructure/ProjectArgus)"
MYRMIDONS_DIR="\$(readlink -f provisioning/Myrmidons)"
PODMAN_SOCK="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/podman/podman.sock"

cat > .env <<EOF
PROJECT_ROOT=\$PROJECT_ROOT
HERMES_DIR=\$HERMES_DIR
ARGUS_DIR=\$ARGUS_DIR
MYRMIDONS_DIR=\$MYRMIDONS_DIR
PODMAN_SOCK=\$PODMAN_SOCK
EOF

# Kill stale aardvark-dns if present (WSL2/rootless podman DNS workaround)
kill \$(cat "\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/containers/networks/aardvark-dns/aardvark.pid" 2>/dev/null) 2>/dev/null || true

echo "  Running: podman compose -f docker-compose.e2e.yml -f e2e/docker-compose.hermes-hub.yml up -d --build"
podman compose \\
  -f docker-compose.e2e.yml \\
  -f e2e/docker-compose.hermes-hub.yml \\
  up -d --build 2>&1 | tail -30

echo "  Waiting 15s for containers to initialize..."
sleep 15

# ─── DNS Workaround: restart NATS-dependent services with direct IPs ───────
get_ip() {
  podman inspect "\$1" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)
nets=d[0]['NetworkSettings']['Networks']
print(list(nets.values())[0]['IPAddress'])"
}

NATS_IP=\$(get_ip odysseus-nats-1 2>/dev/null || echo "")
if [ -z "\$NATS_IP" ]; then
  echo "  WARN: Could not detect NATS container IP — using host-network fallback"
  # host-network fallback for rootlessport-absent hosts
  podman run -d --replace --name odysseus-nats-1 --network=host nats:alpine -js -m 8222 2>&1 | tail -1
  sleep 5
  NATS_IP="localhost"
fi
echo "  NATS IP: \$NATS_IP"

# Restart NATS-dependent services with direct container IP
podman run -d --replace --name odysseus-agamemnon-1 \\
  --network odysseus_homeric-mesh \\
  -p 8080:8080 \\
  -e "NATS_URL=nats://\${NATS_IP}:4222" \\
  odysseus-agamemnon:latest 2>&1 | tail -1

podman run -d --replace --name odysseus-hermes-1 \\
  --network odysseus_homeric-mesh \\
  -p 8085:8085 \\
  -e "NATS_URL=nats://\${NATS_IP}:4222" \\
  -e "HERMES_PORT=8085" \\
  odysseus-hermes:latest 2>&1 | tail -1

sleep 5
AGAMEMNON_IP=\$(get_ip odysseus-agamemnon-1 2>/dev/null || echo "\$NATS_IP")

# argus-exporter — Nestor is local to hermes in this topology
podman run -d --replace --name odysseus-argus-exporter-1 \\
  --network odysseus_homeric-mesh \\
  -p 9100:9100 \\
  -e "AGAMEMNON_URL=http://\${AGAMEMNON_IP}:8080" \\
  -e "NESTOR_URL=http://localhost:8081" \\
  -e "NATS_URL=http://\${NATS_IP}:8222" \\
  odysseus-argus-exporter:latest 2>&1 | tail -1

echo "  Waiting 10s for service connections..."
sleep 10

echo ""
echo "=== Service Status ==="
podman ps --format '{{.Names}} {{.Status}}' | grep odysseus | sort

echo ""
echo "=== Health Checks ==="
curl -sf http://localhost:8080/v1/health && echo " (Agamemnon OK)" || echo "  Agamemnon: FAIL"
curl -sf http://localhost:8081/v1/health && echo " (Nestor OK)"    || echo "  Nestor: FAIL"
curl -sf http://localhost:8085/health && echo " (Hermes OK)"       || echo "  Hermes: FAIL"
curl -sf http://localhost:8222/healthz > /dev/null && echo "  NATS: OK" || echo "  NATS: FAIL"
REMOTE_START
ok "hermes stack started"

# ── Step 3: Launch hello-myrmidon on epimetheus ──────────────────────────────
info "Step 3: Launching hello-myrmidon worker on epimetheus"

ssh "$EPI_SSH" bash -s <<REMOTE_MYRMIDON
set -euo pipefail

# Clone Odysseus if not present
if [ ! -d ~/Odysseus ]; then
  echo "  Cloning Odysseus..."
  git clone --quiet https://github.com/HomericIntelligence/Odysseus.git ~/Odysseus
fi
cd ~/Odysseus

# Ensure the Myrmidons submodule is initialized (that's all we need on epimetheus)
git submodule update --init provisioning/Myrmidons --quiet
echo "  Myrmidons submodule ready"

# Stop any stale worker
pkill -f "provisioning/Myrmidons/hello-world/main.py" 2>/dev/null || true
sleep 1

# Launch
echo "  Starting hello-myrmidon → NATS on ${HERMES_IP}:4222"
NATS_URL="nats://${HERMES_IP}:4222" \\
  nohup python3 provisioning/Myrmidons/hello-world/main.py \\
  > /tmp/hello-myrmidon.log 2>&1 &
MYRM_PID=\$!
sleep 3

# Verify it's still running
if kill -0 \$MYRM_PID 2>/dev/null; then
  echo "  hello-myrmidon running (PID \$MYRM_PID)"
  echo "  Log tail:"
  tail -5 /tmp/hello-myrmidon.log | sed 's/^/    /'
else
  echo "  ERROR: hello-myrmidon exited. Log:"
  cat /tmp/hello-myrmidon.log | tail -20
  exit 1
fi
REMOTE_MYRMIDON
ok "epimetheus myrmidon launched"

# ── Step 4: Final verification ───────────────────────────────────────────────
info "Step 4: Cross-host connectivity check"

# Verify NATS sees the remote myrmidon connection
CONNS=$(ssh "$HERMES_SSH" "curl -sf http://localhost:8222/varz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connections',0))")
if [ "${CONNS:-0}" -ge 2 ]; then
  ok "NATS reports ${CONNS} connections (includes remote myrmidon)"
else
  warn "NATS reports ${CONNS} connections — myrmidon may not have connected yet"
  warn "Run: ssh epimetheus 'tail -20 /tmp/hello-myrmidon.log'"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo -e "║  ${GREEN}Hermes-Hub stack ready.${NC}                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  hermes services:                                        ║"
echo "║    Agamemnon:   http://${HERMES_IP}:8080/v1/health        ║"
echo "║    Nestor:      http://${HERMES_IP}:8081/v1/health        ║"
echo "║    Hermes:      http://${HERMES_IP}:8085/health           ║"
echo "║    NATS:        http://${HERMES_IP}:8222/healthz          ║"
echo "║    Prometheus:  http://${HERMES_IP}:9090                  ║"
echo "║    Grafana:     http://${HERMES_IP}:3001                  ║"
echo "║  epimetheus:                                             ║"
echo "║    Myrmidon:    ssh epimetheus 'tail -20 /tmp/hello-myrmidon.log'  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Run E2E validation:  just hermes-hub-test               ║"
echo "║  Tear down:           just hermes-hub-down               ║"
echo "╚══════════════════════════════════════════════════════════╝"
