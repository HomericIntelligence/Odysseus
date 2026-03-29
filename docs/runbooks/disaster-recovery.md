# Runbook: Disaster Recovery

This runbook covers recovery scenarios for the HomericIntelligence ecosystem, including total loss of the primary Agamemnon host.

---

## Scenario 1: Primary Agamemnon Host Goes Down

### Immediate impact

- Agent lifecycle API is unavailable.
- New tasks cannot be queued.
- ProjectHermes stops receiving webhooks (no new NATS events).
- Existing agents running on other hosts continue running until they poll Agamemnon for instructions.
- NATS JetStream continues operating on any surviving leaf nodes.

### Recovery steps

#### Step 1: Diagnose the failure

```bash
# Check if Agamemnon process is running
systemctl status agamemnon   # or: ps aux | grep agamemnon

# Check if the host itself is reachable
ping 172.20.0.1

# Check disk space (common cause of process death)
df -h /
```

#### Step 2: Attempt in-place restart

If the host is reachable but the process is down:

```bash
systemctl start agamemnon
# Wait 10 seconds
curl http://172.20.0.1:8080/health
```

If this succeeds, proceed to Step 5 (verify state). If not, proceed to Step 3.

#### Step 3: Restore Agamemnon on a fresh host

If the primary host is unrecoverable, provision a new host (see `add-new-host.md` for the base setup), then restore Agamemnon state:

```bash
# On the new host: install and start Agamemnon
# Follow ~/ProjectAgamemnon/ for installation instructions

# Update AGAMEMNON_URL in your environment to point to the new host
export AGAMEMNON_URL=http://<new-host-tailscale-ip>:8080
```

#### Step 4: Re-apply state from Myrmidons

Myrmidons holds the declarative desired state for all agents. Apply it to the fresh Agamemnon instance to reconstruct the agent registry:

```bash
cd /path/to/Odysseus
just apply-all
```

This calls `just apply` in `provisioning/Myrmidons`, which reads all YAML manifests and reconciles agents, tasks, and configurations via the Agamemnon REST API.

Verify agents are registered:

```bash
curl $AGAMEMNON_URL/v1/agents | jq 'length'
# Should match the number of agent manifests in Myrmidons
```

#### Step 5: Replay missed NATS events from JetStream

If consumers (ProjectTelemachy, ProjectArgus, ProjectScylla) missed events during the outage, replay them from JetStream:

```bash
# List available streams
nats stream list

# Check the last sequence number processed by each consumer
nats consumer info homeric-tasks <consumer-name>

# Replay from a specific sequence number
nats consumer next homeric-tasks <consumer-name> --count 1000
```

Durable consumers will automatically catch up from their last acknowledged sequence on reconnect. Manual replay is only needed if you want to reprocess events for debugging.

#### Step 6: Verify ProjectHermes webhook receiver

Ensure ProjectHermes is configured with the new Agamemnon host's webhook URL:

```bash
cd infrastructure/ProjectHermes
# Update the AGAMEMNON_URL in the ProjectHermes config
just restart
```

Confirm webhooks are flowing:

```bash
nats sub "hi.>" --count 5
# Should see events when agents are created/started
```

#### Step 7: Notify all submodule services

Restart or reconfigure any services that had a hardcoded reference to the old host's IP:
- ProjectArgus (scrape targets)
- ProjectTelemachy (AGAMEMNON_URL)
- ProjectKeystone (secret injection targets)

---

## Scenario 2: NATS Cluster Goes Down

#### Step 1: Restart the primary NATS server

```bash
nats-server -c /etc/nats/server.conf
```

#### Step 2: Verify leaf nodes reconnect

Leaf nodes (secondary hosts) will automatically attempt to reconnect. Check connectivity:

```bash
nats server info
# All leaf nodes should appear in the cluster info
```

#### Step 3: Verify JetStream state is intact

```bash
nats stream report
# Verify message counts match pre-outage values
# JetStream persists to disk at the store_dir in server.conf
```

---

## Scenario 3: Re-bootstrap a Completely Fresh Host from Scratch

Use this when setting up a net-new replacement for a completely lost host with no data recovery possible.

```bash
# 1. Clone Odysseus with all submodules
git clone --recurse-submodules https://github.com/homeric-intelligence/Odysseus.git
cd Odysseus

# 2. Install pixi and just
curl -fsSL https://pixi.sh/install.sh | bash
pixi install

# 3. Bootstrap submodules
just bootstrap

# 4. Install and start Agamemnon (follow ~/ProjectAgamemnon/)

# 5. Install and start NATS with server config
nats-server -c configs/nats/server.conf &

# 6. Install and start Nomad server
nomad agent -config configs/nomad/server.hcl &

# 7. Apply desired state from Myrmidons
just apply-all

# 8. Start ProjectHermes event bridge
just hermes-start

# 9. Start ProjectArgus observability
just argus-start

# 10. Verify
just status
curl $AGAMEMNON_URL/health
```

---

## Recovery Checklist

- [ ] Agamemnon is running and `/health` returns 200
- [ ] `just apply-all` completed without errors
- [ ] Agent count matches expected count in `provisioning/Myrmidons/`
- [ ] NATS server is running and all leaf nodes have reconnected
- [ ] JetStream stream report shows correct message counts
- [ ] ProjectHermes is receiving webhooks and publishing to NATS
- [ ] ProjectArgus Grafana dashboard shows all hosts
- [ ] Nomad `node status` shows all hosts as ready
