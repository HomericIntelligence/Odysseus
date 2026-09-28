# Runbook: Disaster Recovery

This runbook covers recovery scenarios for the HomericIntelligence ecosystem,
including loss of an Agamemnon host. Bind the exact deployed revision,
topology, service manager, state location, and recovery target before acting.
Commands in this runbook are diagnostics unless an operator has approved the
corresponding live-state effect.

---

## Scenario 1: Primary Agamemnon Host Goes Down

### Immediate impact

- Agent lifecycle API is unavailable.
- New tasks cannot be queued.
- Hermes and NATS have independent health and may continue handling signed
  webhooks and events; do not infer their state from Agamemnon's state.
- Existing agents may continue their current process, but lifecycle and task
  transitions that require Agamemnon are unavailable.
- JetStream remains available only where a surviving, verified NATS server has
  its expected storage and quorum.

### Recovery steps

### Step 1: Diagnose the failure

Set the health URL from the deployment record; do not substitute a remembered
host address.

```bash
AGAMEMNON_HEALTH_URL="${AGAMEMNON_HEALTH_URL:?set the verified Agamemnon base URL}"
set -o pipefail
curl --fail --silent --show-error "${AGAMEMNON_HEALTH_URL%/}/v1/health" \
  | python3 -c 'import json, sys; body=json.load(sys.stdin); assert body.get("status") == "ok"'
df -h /
```

Inspect the process through the service manager recorded for that deployment.
For example, use `systemctl status agamemnon` only when the deployed unit is
actually named `agamemnon`; otherwise inspect the bound container or process.

### Step 2: Attempt in-place restart

If the host is reachable but the process is down, first preserve logs and
identify the cause. Obtain approval for the restart, use the deployment's
recorded service-manager command, and then re-run the versioned health probe
above. A healthy process is not proof that registry state is complete; continue
to Step 4. If the process cannot be restored, continue to Step 3.

### Step 3: Restore Agamemnon on a fresh host

If the host is unrecoverable, obtain approval for the replacement target and
provision it using [`add-new-host.md`](add-new-host.md). Install the exact
known-good Agamemnon revision and restore its deployment configuration and
secrets through the operator-owned secret path. Set `AGAMEMNON_URL` for clients
only after the replacement endpoint, authentication, and network exposure have
been verified; this runbook does not choose or discover that address.

### Step 4: Restore or reconcile agent state

Restore the last verified Agamemnon state backup when one is available. The
current pinned Myrmidons repository is a dataset package and has no `apply`
recipe; Odysseus therefore has no `apply-all` recovery command. A checkout of
authored YAML is not proof of live desired state.

If no backup is available, stop before changing live state. Query the fresh
reconciler, verify that no conflicting task is active, and obtain explicit
operator approval for the exact version-matched dataset and effects. Use only
a documented reconciler path from the pinned Agamemnon checkout. If that path
is absent or cannot prove convergence, record the recovery as incomplete and
escalate rather than inventing a wrapper.

After an approved restoration or reconciliation, use Agamemnon's documented
status endpoint to compare the live registry with the approved recovery
inventory. Preserve that readback as the recovery receipt.

### Step 5: Verify NATS consumer state

Read the live stream and consumer inventory and compare it with the pre-incident
receipt. Do not run a generic `nats consumer next` command: it can advance a
consumer and is not a topology-neutral replay mechanism. If a particular
consumer requires recovery, bind its exact stream, durable name, last known
sequence, idempotence behavior, and component-owned recovery procedure. Obtain
operator approval for that replay and retain the before/after consumer
readbacks as its receipt. If no compatible procedure exists, report recovery
as incomplete.

### Step 6: Verify Hermes and NATS independently

Hermes does not use an Agamemnon callback URL at the pinned revision. Do not
edit or restart Hermes merely because Agamemnon moved. Use Hermes's own health
and signed-webhook verification procedure, and use an authorized NATS identity
with the least-privilege subject scope when checking publication. A broad
`hi.>` subscription is not a generic recovery probe.

### Step 7: Notify all submodule services

Search the exact deployed manifests and service environments for consumers of
the old Agamemnon endpoint. Reconfigure only verified consumers, using their
component runbooks and an approved endpoint change. Do not infer consumers from
this document or restart unrelated services.

---

## Scenario 2: NATS Cluster Goes Down

### Step 1: Bind the failed NATS deployment

Identify the exact server or cluster revision, service manager, config,
credential source, JetStream storage path, and last good stream/peer receipt.
Preserve logs and storage before changing the service. The source files in
`configs/nats/` do not prove which config or credentials the host deployed.

### Step 2: Verify leaf nodes reconnect

After approval, restart through the deployment-owned service manager. Do not
launch a second ad hoc `nats-server` process against the same ports or storage.
Read back the actual leaf connections and compare their identities with the
bound topology; report missing peers rather than assuming automatic recovery.

### Step 3: Verify JetStream state is intact

Use an authorized system identity to obtain the stream and consumer reports.
Compare them with the pre-incident receipt and verify the deployed storage
path. A running server or a checked-in `store_dir` alone is not evidence that
the expected JetStream state survived.

---

## Scenario 3: Re-bootstrap a Completely Fresh Host from Scratch

Use this only after an operator approves the exact replacement host, known-good
Odysseus revision, component pins, intended topology, and recovery inventory.

1. Provision the host through [`add-new-host.md`](add-new-host.md), using the
   approved network and secret-distribution path.
2. Check out the approved immutable Odysseus commit and initialize its exact
   submodule pins. Do not update gitlinks while recovering a host.
3. Install the root and component dependencies from their locked manifests.
4. Restore NATS only through the bound deployment procedure and verified
   storage backup. Do not directly launch the checked-in config against live
   ports or enable the optional Nomad path unless those actions were separately
   approved for this topology.
5. Restore Agamemnon and desired state as described in Scenario 1, Steps 3-4.
6. Start only the services in the approved recovery inventory, using each
   component's deployment procedure.
7. Record the health, state, peer, stream, and consumer readbacks that actually
   completed. Preserve a truthful incomplete result for any unavailable check.

---

## Recovery Checklist

- [ ] Agamemnon `/v1/health` returns HTTP 200 with JSON `status` equal to `ok`
- [ ] A verified Agamemnon backup was restored, or an explicitly approved,
      version-matched reconciliation completed with a convergence receipt
- [ ] Live agent state matches the approved recovery inventory
- [ ] The approved NATS topology is healthy, or NATS was explicitly out of scope
- [ ] JetStream and consumer readbacks match the bound recovery inventory
- [ ] Hermes was independently verified, or was explicitly out of scope
- [ ] Each approved observability target is reporting, or its gap is recorded
- [ ] Optional Nomad state was verified only if Nomad belongs to this deployment
