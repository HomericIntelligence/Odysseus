# Runbook: Add a New Host to the HomericIntelligence Mesh

## Prerequisites

- The new host is running WSL2 (or a compatible Linux environment).
- You have SSH access to the new host.
- Tailscale is available for installation on the new host.
- You have access to the Agamemnon primary host's API at `http://172.20.0.1:8080` (or your configured `AGAMEMNON_URL`).

---

## Steps

### 1. Install Agamemnon agent

On the new host, install the Agamemnon agent. It registers itself as a peer and exposes the REST API locally.

```bash
# Follow the Agamemnon installation guide
# Refer to ~/ProjectAgamemnon/ for current instructions
```

Configure the agent to use the primary host as the sync target by setting the `AGAMEMNON_URL` environment variable to the primary host's Agamemnon API URL.

### 2. Install and configure Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey=<your-tailscale-authkey>
```

Verify the new host appears in your Tailscale admin console and has been assigned an IP in the mesh network.

### 3. Register the new host with ProjectHermes host-sync

ProjectHermes maintains a synchronized host list. After Tailscale is up, trigger a host-sync from the primary host:

```bash
# On the primary host, from the Odysseus repo root
curl -X POST http://172.20.0.1:8080/v1/host-sync \
  -H "Content-Type: application/json" \
  -d '{"action": "scan"}'
```

Verify the new host appears in the Agamemnon host list:

```bash
curl http://172.20.0.1:8080/v1/hosts | jq '.[] | .hostname'
```

### 4. Deploy a NATS leaf node

The new host needs a NATS leaf node to participate in the event mesh. Copy the leaf node config from this repo:

```bash
cp configs/nats/leaf.conf /etc/nats/leaf.conf
# Edit leaf.conf: set the remotes.url to the primary NATS server's Tailscale IP
```

Start the NATS leaf node:

```bash
nats-server -c /etc/nats/leaf.conf &
```

Verify connectivity:

```bash
nats --server nats://localhost:4222 sub "hi.>" &
# Should see events forwarded from the primary cluster
```

### 5. Deploy a Nomad client agent

Copy the client config and start Nomad:

```bash
cp configs/nomad/client.hcl /etc/nomad.d/client.hcl
# Edit client.hcl: set client.servers to the primary Nomad server's Tailscale IP

nomad agent -config /etc/nomad.d/client.hcl &
```

Verify the new node appears in Nomad:

```bash
nomad node status
# New host should appear with status "ready"
```

### 6. Verify ProjectArgus receives metrics

ProjectArgus scrapes all known hosts. After the new host is registered, check that Argus has picked it up:

```bash
# From the primary host
cd infrastructure/ProjectArgus && just status
# Or check the Grafana dashboard for the new host's node_exporter metrics
```

If the host does not appear within 5 minutes, check the Argus service discovery config and ensure node_exporter is running on the new host.

---

## Verification Checklist

- [ ] Agamemnon agent is running on new host
- [ ] New host appears in `curl http://172.20.0.1:8080/v1/hosts`
- [ ] New host appears in Tailscale admin console
- [ ] NATS leaf node is running and connected to primary cluster
- [ ] Nomad node status shows new host as "ready"
- [ ] ProjectArgus Grafana dashboard shows new host metrics
