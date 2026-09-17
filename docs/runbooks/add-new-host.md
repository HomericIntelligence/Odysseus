# Runbook: Add a Host to an Approved HomericIntelligence Environment

This runbook prepares and verifies one explicitly selected host. It does not
define a generic mesh-enrollment protocol or authorize a multi-host deployment.
The current Myrmidons schema enumerates `local`, `docker`, and a future-reserved
`nomad` discriminator, while runtime scheduling currently implements `local`
and `docker`. Multi-host Nomad scheduling remains target state in
[Proposed ADR-021](../adr/021-defer-multi-host-nomad-scheduling.md).

The pinned Agamemnon service does not expose a host-sync or peer-registration
contract, and Hermes is an inbound webhook bridge rather than a host inventory
owner. Do not call historical `/v1/host-sync` or `/v1/hosts` routes, install an
“Agamemnon agent,” or represent a successful local install as peer registration.

## Authority and stop conditions

Before any install, enrollment, firewall, remote-write, or service-start action:

1. identify the exact host and operator-owned environment;
2. record the immutable Odysseus and component revisions being evaluated;
3. read back the host's current OS, network interfaces, firewall, services, and
   relevant runtime state;
4. define the exact intended effects and rollback route; and
5. obtain operator approval for that host and effect set.

Stop when the target identity, current state, supported component interface,
credential path, approval, or post-state probe is missing. A historical host
name, address, topology report, or successful command from another machine is
not current evidence. Do not copy an address from this repository.

## 1. Bind the host and repository state

On the selected host, record read-only identity and repository evidence:

```bash
hostname
uname -a
git -C ~/Projects/Odysseus rev-parse HEAD
git -C ~/Projects/Odysseus submodule status --recursive
```

Resolve any missing or drifting component before continuing. A component change
belongs in its own repository; moving an Odysseus gitlink requires separate
integration approval for the exact reviewed commit.

Check local worker prerequisites without invoking Tailscale:

```bash
cd ~/Projects/Odysseus
just doctor --role worker
```

This is the default for local development and CI. Record failures as failures;
do not infer an install or a working topology from a skipped check.

## 2. Install approved local prerequisites

After the operator approves the exact package and service effects reported by
the read-only check:

```bash
just doctor --role worker --install
just doctor --role worker
```

`--install` may install missing local dependencies, initialize pinned
submodules, or enable a required local service. It does not change firewall
policy and does not start the HomericIntelligence application stack. Review the
actual post-state rather than relying on the command's exit alone.

## 3. Verify an approved cross-host topology

Skip this section unless a multi-host environment and exact host set are
explicitly in scope. Enroll the host through the operator's current,
officially supported Tailscale procedure. Keep enrollment credentials out of
command history, process arguments, logs, and the repository.

After enrollment, bind one literal peer IP from the approved live inventory and
run the repository-owned topology check. Repeat for each approved peer:

```bash
: "${PEER_TAILSCALE_IP:?set one operator-verified literal peer IP}"
just doctor --role worker --cross-host --worker-ip "$PEER_TAILSCALE_IP"
```

`just doctor --cross-host --capability-only` checks only local Tailscale
capability. It is not peer reachability or topology evidence.

If the execution environment cannot run Tailscale, report topology verification
as unavailable and rely on an authorized CI or operator environment. Do not
convert a local-only doctor result into cross-host evidence.

### Firewall boundary

Read the active firewall and interface policy before proposing a change. Adding
the entire `tailscale0` interface to a trusted zone is a broad host-security
change, not a routine prerequisite. Prefer deployment-owned least-privilege
rules for the exact listeners and peers.

The doctor does not apply or treat whole-interface trusted-zone membership as
readiness. Use a deployment-owned procedure that binds the exact listeners,
peers, current policy, change delta, rollback, operator approval, and
post-change readback. An inactive or unavailable firewall control is not
permission to substitute a different policy.

## 4. Select only a supported deployment path

Host preparation does not select or activate services. Use
[`../deployment.md`](../deployment.md) and the exact pinned component's README
to choose a separately approved path.

- **Agamemnon/Myrmidons:** query the configured reconciler and current desired
  state through its documented authenticated interface. The checked-in
  Myrmidons data is not proof of live state, and no host-sync API is available.
- **NATS:** the checked-in primary and leaf configurations have unresolved
  exact-pin client and leaf-auth compatibility gates. Do not launch a leaf or
  borrow another service's credentials. Follow
  [`enable-nats-auth.md`](enable-nats-auth.md) only after compatible paths are
  reviewed, integrated, and approved.
- **Nomad:** do not start a generic background client. Use Nomad only for an
  existing, operator-owned deployment with rendered host-specific config,
  scoped ACL credentials, persistent state, a service manager, and authenticated
  registration readback. It is not the default Myrmidons scheduler.
- **Argus:** do not assume automatic discovery. Bind the deployed scrape or
  service-discovery configuration and prove the expected target and metrics
  through the operator-owned observability path.

Never launch NATS or Nomad with an untracked `&` process from this runbook.
Activation must use a deployment-owned lifecycle with logs, health checks,
restart behavior, and cleanup.

## Completion receipt

Host addition is complete only when the receipt records:

- the exact host identity and immutable repository/component revisions;
- explicit approval and actual post-state for every local or remote effect;
- a passing local worker check;
- a passing `--cross-host` check when multi-host topology is in scope;
- the supported, authenticated interface and desired-state readback for each
  activated component;
- least-privilege firewall and credential evidence; and
- service-manager health, restart, and cleanup evidence for every started
  process.

List unavailable or failed checks as incomplete. Do not claim peer
registration, host discovery, NATS federation, Nomad readiness, or Argus
coverage unless that exact observable result was produced by the current,
approved deployment.
