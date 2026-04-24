# Deployment Guide

## End-to-End Ecosystem Deployment

This guide walks through deploying the HomericIntelligence distributed agent mesh from scratch on a fresh infrastructure. Follow these steps top-to-bottom to bring the entire ecosystem online.

---

## Prerequisites

Before starting, ensure the following are installed and available on all target hosts:

### 1. Pixi (Package Manager)

Pixi manages Python environments and project dependencies across all submodules.

```bash
# Install Pixi (see https://pixi.sh/latest/#installation)
curl -fsSL https://pixi.sh/install.sh | bash
```

Verify installation:

```bash
pixi --version
```

### 2. Podman (Container Runtime)

All services and agents run in Podman containers on a shared `homeric-mesh` network.

```bash
# On Debian/Ubuntu:
sudo apt-get install -y podman podman-compose

# On RHEL/Fedora/CentOS:
sudo dnf install -y podman podman-compose
```

Start the Podman daemon (if not already running):

```bash
sudo systemctl start podman
```

Verify installation:

```bash
podman --version
```

### 3. Tailscale (VPN Mesh)

All inter-host traffic flows over Tailscale. Install on every host that will participate in the mesh:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey=<your-tailscale-authkey>
```

Verify connectivity:

```bash
sudo tailscale ip -4
```

Record the Tailscale IP addresses; you will need them when configuring NATS and Nomad across hosts.

### 4. Just (Task Runner)

The `just` command-line tool orchestrates setup, deployment, and operational tasks:

```bash
# On macOS:
brew install just

# On Linux:
# Via Cargo (requires Rust):
cargo install just

# Or download a binary from: https://github.com/casey/just/releases
```

Verify installation:

```bash
just --version
```

---

## Step 1: Bootstrap the Repository

Clone Odysseus and initialize all git submodules:

```bash
git clone https://github.com/HomericIntelligence/Odysseus.git
cd Odysseus
git submodule update --init --recursive
```

Or use the one-command bootstrap task:

```bash
just bootstrap
```

This downloads and initializes all 12 submodule repositories into their designated directories.

---

## Step 2: Install Dependencies

Install project-wide Python dependencies using Pixi:

```bash
pixi install
```

This resolves dependencies across all submodules and creates the environment lock file.

---

## Step 3: Build All Components

Build all compilable submodules (C++, CMake, and Mojo sources):

```bash
just build
```

Build artifacts are placed in `build/` subdirectories:

- `build/ProjectAgamemnon/` — Planning and orchestration engine
- `build/ProjectNestor/` — Research and ideation service
- `build/ProjectCharybdis/` — Chaos and resilience testing
- `build/ProjectKeystone/` — Transport layer (BlazingMQ + NATS)
- `build/ProjectOdyssey/` — ML research sandbox

Verify all builds succeeded:

```bash
ls -la build/
```

---

## Step 4: Configure NATS (Message Bus)

NATS JetStream is the cross-host event bus. Configure it on the primary host:

### 4a. Review the NATS Configuration

The canonical NATS server config is at `configs/nats/server.conf`. It configures:

- JetStream persistence
- TLS (if enabled)
- Leaf nodes (for multi-cluster federation)
- Max connections and per-client limits

For a single-host setup, the default config requires no changes.

### 4b. Start the NATS Server

```bash
podman run -d \
  --name nats-server \
  --network homeric-mesh \
  -p 4222:4222 \
  -v $(pwd)/configs/nats/server.conf:/etc/nats/server.conf:ro \
  nats:3.12.0 -c /etc/nats/server.conf
```

Verify NATS is running:

```bash
podman logs nats-server
```

You should see: `Server is ready for connections on 0.0.0.0:4222`

### 4c. Configure Leaf Nodes (Multi-Host Only)

If deploying across multiple hosts, configure leaf node connections in `configs/nats/leaf.conf` to federate the NATS clusters over Tailscale. See `docs/runbooks/add-new-host.md` for details.

---

## Step 5: Configure Nomad (Job Scheduler)

Nomad schedules and manages all agent workloads. Configure it on the primary host:

### 5a. Review the Nomad Configuration

The canonical Nomad configs are at:

- `configs/nomad/server.hcl` — Primary cluster controller
- `configs/nomad/client.hcl` — Worker node config

For a single-host setup, run both server and client on the same host.

### 5b. Start Nomad Server

```bash
mkdir -p /var/nomad/{data,plugins}
sudo chown nomad:nomad /var/nomad

podman run -d \
  --name nomad-server \
  --network homeric-mesh \
  -p 4646:4646 \
  -p 4647:4647 \
  -p 4648:4648/udp \
  -v /var/nomad:/nomad/data \
  -v $(pwd)/configs/nomad/server.hcl:/etc/nomad/server.hcl:ro \
  hashicorp/nomad:1.6 agent -config /etc/nomad/server.hcl
```

### 5c. Start Nomad Client

```bash
podman run -d \
  --name nomad-client \
  --network homeric-mesh \
  -v /var/nomad:/nomad/data \
  -v $(pwd)/configs/nomad/client.hcl:/etc/nomad/client.hcl:ro \
  -v /var/run/podman:/var/run/podman:ro \
  hashicorp/nomad:1.6 agent -config /etc/nomad/client.hcl
```

Verify Nomad is running:

```bash
nomad status
```

---

## Step 6: Start ProjectKeystone (Transport Layer)

ProjectKeystone wraps BlazingMQ (intra-host) and NATS (cross-host) behind a unified event interface. Start it on all hosts:

```bash
just keystone-start
```

This task:

1. Builds ProjectKeystone (if not already built)
2. Starts the Keystone service in a Podman container
3. Registers it as the event bus for all downstream services

Verify connectivity:

```bash
podman logs keystone
```

---

## Step 7: Start ProjectAgamemnon (Control Plane)

ProjectAgamemnon is the central orchestration engine. It coordinates planning, reconciliation, and HMAS (Hierarchical Multi-Agent System) orchestration.

```bash
just agamemnon-start
```

This task:

1. Builds ProjectAgamemnon (if not already built)
2. Starts the Agamemnon API service at `http://localhost:8080`
3. Registers GitHub for backing storage

Verify it is running:

```bash
curl http://localhost:8080/health
```

Expected response: `{"status":"healthy"}`

---

## Step 8: Deploy Initial Agent Fleet (Myrmidons)

The Myrmidons repository contains declarative YAML manifests describing the desired agent state. Apply them via Agamemnon's reconciliation API:

```bash
just apply-all
```

This task:

1. Reads all YAML files from `provisioning/Myrmidons/`
2. Submits them to Agamemnon via the `/apply` API endpoint
3. Agamemnon creates Nomad jobs to instantiate the agents

Monitor agent startup:

```bash
nomad status
```

You should see agent jobs transitioning to the `running` state.

---

## Step 9: Start ProjectHermes (External Bridge)

ProjectHermes bridges external service events (Slack, GitHub, email) into NATS and handles outbound message delivery:

```bash
just hermes-start
```

Verify it is running:

```bash
podman logs hermes
```

---

## Step 10: Start ProjectArgus (Observability Stack)

ProjectArgus provides metrics, logging, and dashboards via Prometheus, Loki, and Grafana:

```bash
just argus-start
```

This task:

1. Starts Prometheus (metrics scraping)
2. Starts Loki (log aggregation)
3. Starts Grafana (dashboards)
4. Configures Promtail (log shipper)

Access Grafana:

```
http://localhost:3000
```

Default credentials: `admin / admin`

---

## Step 11: Verification

Verify the full ecosystem is operational:

### 11a. Check All Services

```bash
just status
```

This shows git status across all submodules and should show no uncommitted changes (all pinned at known-good commits).

### 11b. Verify Network Connectivity

Confirm all hosts can reach each other over Tailscale:

```bash
sudo tailscale ping <peer-tailscale-ip>
```

### 11c. Check Nomad Job Status

```bash
nomad status
```

All agent jobs should be in the `running` state.

### 11d. Verify NATS JetStream

```bash
podman exec nats-server nats stream ls
```

You should see several streams (e.g., `research-requests`, `orchestration-commands`).

### 11e. Test ProjectNestor (Research Service)

Submit a research request and verify it is processed:

```bash
curl -X POST http://localhost:8080/research \
  -H "Content-Type: application/json" \
  -d '{"query":"test query"}'
```

Monitor the response through Agamemnon's task queue.

---

## Step 12: Production Hardening

Before running in production, complete these additional steps:

### 12a. Enable TLS

Update `configs/nats/server.conf` and `configs/nomad/server.hcl` to enable TLS certificates.

### 12b. Configure Persistent Storage

Ensure NATS, Nomad, and Loki are backed by persistent storage (not ephemeral containers). Use mounted volumes or cloud object storage.

### 12c. Set Up Monitoring Alerts

Configure Grafana alert rules to notify on service degradation, high error rates, or agent failures.

### 12d. Enable Audit Logging

Enable GitHub audit logging to capture all Agamemnon decisions for compliance and debugging.

### 12e. Secure Tailscale

Configure Tailscale ACLs to restrict which hosts can communicate. See `docs/runbooks/add-new-host.md`.

---

## Troubleshooting

### Services Fail to Start

Check container logs:

```bash
podman logs <container-name>
```

### Network Connectivity Issues

Verify Tailscale is connected:

```bash
sudo tailscale status
```

If not connected, re-authenticate:

```bash
sudo tailscale up --authkey=<new-authkey>
```

### Agents Not Spawning

Verify Nomad client is registered:

```bash
nomad node status
```

If no clients appear, restart the Nomad client:

```bash
podman restart nomad-client
```

### NATS Cluster Not Forming

Check NATS logs and verify all hosts have matching NATS cluster IDs in their configs:

```bash
podman logs nats-server
```

---

## Next Steps

After deployment is complete:

1. **Add New Hosts** — See `docs/runbooks/add-new-host.md` to scale the mesh.
2. **Add New Agent Types** — See `docs/runbooks/add-new-agent-type.md` to create custom agents.
3. **Disaster Recovery** — Review `docs/runbooks/disaster-recovery.md` for backup and recovery procedures.
4. **Architecture Deep Dive** — Read `docs/architecture.md` for system internals and component relationships.
