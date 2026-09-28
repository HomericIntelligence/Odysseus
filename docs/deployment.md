# Deployment Guide

## End-to-End Ecosystem Deployment

This guide walks through the checked-in deployment entry points. The current
Myrmidons schema enumerates `local`, `docker`, and a future-reserved `nomad`
discriminator; current runtime scheduling implements `local` and `docker`.
The Tailscale and Nomad sections below apply only to an explicitly operated multi-host
environment; they are not prerequisites for local development or CI and do not
prove that the Proposed ADR-021 target is deployed. Confirm desired state
through Agamemnon and the component runbooks before making remote changes.

---

## Prerequisites

Before starting, ensure the following are installed and available on all target hosts:

### 1. Pixi (Package Manager)

Pixi manages the Odysseus orchestration environment and the C++/Mojo toolchain
used by root `just` recipes. Each component repository owns its own dependency
environment.

```bash
# Install Pixi (see https://pixi.sh/latest/#installation)
curl -fsSL https://pixi.sh/install.sh | bash
```

Verify installation:

```bash
pixi --version
```

### 2. Podman (Container Runtime)

Containerized services and `docker` agents use Podman. Agents whose deployment
type is `local` do not require a container.

```bash
# On Debian/Ubuntu:
sudo apt-get install -y podman podman-compose

# On RHEL/Fedora/CentOS:
sudo dnf install -y podman podman-compose
```

Podman is daemonless for ordinary container commands. Enable its rootless API
socket only when an API consumer, such as the optional Nomad driver path,
requires it:

```bash
systemctl --user enable --now podman.socket
```

Verify installation:

```bash
podman --version
```

### 3. Tailscale (Optional Multi-Host VPN Mesh)

The checked-in multi-host paths use Tailscale. Install it only on hosts that
will participate in such an operator-approved mesh; it is neither a local nor
a CI prerequisite. The network operator must use the current vendor enrollment
procedure and an approved secret-input mechanism. Never place an auth key in a
command argument, environment variable, shell history, or repository file.
After enrollment, obtain the approved addresses from an operator-owned
readback; do not infer or copy them from documentation.

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

This downloads and initializes all 15 component submodule repositories at the
recorded gitlink commits (16 canonical repositories including Odysseus).

---

## Step 2: Install Dependencies

Install the Odysseus root toolchain using Pixi:

```bash
pixi install
```

This resolves the root environment from `pixi.toml` and `pixi.lock`. It does not
replace the dependency setup documented by each submodule.

---

## Step 3: Build the Root-Supported Targets

Build the root recipe's supported C++, CMake, Mojo, and example targets:

```bash
just build
```

Targets that actually run place artifacts in `build/` subdirectories:

- `build/Agamemnon/` — Planning and orchestration engine
- `build/Nestor/` — Research-request intake and status service
- `build/Charybdis/` — Chaos and resilience testing
- `build/Keystone/` — In-process MessageBus and optional NATS bridge
- `build/Odyssey/` — ML research sandbox
- `build/Myrmidons/hello-world/` — Hello-world C++ myrmidon

The successful exit of `just build` is evidence only for targets it actually
attempted. Review its output and record every explicit skip; do not report a
skipped target as built. Artifact inspection is supplementary inventory, not
proof of build success:

```bash
test -d build && find build -maxdepth 2 -type f -print
```

---

## Step 4: Configure NATS (Message Bus)

NATS JetStream is the cross-host event bus. The checked-in broker policy is
not currently deployable by the complete exact-pin ecosystem; bind and clear
the compatibility gates below before any activation.

### 4a. NATS Authentication Prerequisites (Required Before Starting NATS)

ADRs 008–010 are Proposed at this revision. The checked-in NATS configuration
and a live-state readback, not proposal status, determine what the deployed
server enforces. The ADR links below provide design context for these steps.

The canonical NATS config enforces mutual TLS (`verify_and_map`) and
subject-scoped authorization. Enforcement is fail-closed, but several exact-pin
clients cannot yet satisfy it: Agamemnon and Nestor lack the complete client
certificate configuration, Telemachy does not load a client certificate,
Hermes does not pass its constructed SSL context to the publisher connection,
and the Odysseus console has no dedicated account. Do not borrow another
role's credentials.

The four checked-in application accounts are also isolated NATS subject and
JetStream spaces. Without explicit, reviewed exports/imports, that topology
cannot carry the cross-role fan-out required by Accepted ADR-002 and ADR-005.
Proposed ADR-024 describes one possible resolution but supplies no deployment
authority. Treat this account-topology conflict as a separate stop condition
even after every client can present valid credentials.

Consequently, do not start this config as the ecosystem broker at the current
pins. First land, review, and integrate compatible least-privilege client paths,
then follow [`runbooks/enable-nats-auth.md`](runbooks/enable-nats-auth.md). An
isolated broker canary with disposable credentials, storage, and no production
clients is validation evidence only; it is not a deployment.

### 4b. Review the NATS Configuration

The canonical NATS server config is at `configs/nats/server.conf`. It configures:

- JetStream persistence
- Mutual-TLS authentication with `verify_and_map` (ADR-010)
- Subject-scoped account authorization per the `hi.*` schema (ADR-005)
- Leaf nodes (for multi-cluster federation)
- Authentication (fail-closed): client connections would be authenticated via
  cert-mapped subject-scoped accounts (`verify_and_map`, ADR-010), so no client
  token is required. The primary server's leaf listener reads
  four independent `$NATS_LEAF_<ACCOUNT>_PASSWORD` variables, for HERMES,
  AGENTS, KEYSTONE, and TELEMACHY. Each `leaf-<lowercase-account>` user is
  bound to that account. Supply nonempty passwords through deployment secrets.
- Cluster route authorization (multi-server clusters only): the `cluster {}`
  listener on port 6222 reads `$NATS_CLUSTER_USER` and
  `$NATS_CLUSTER_PASSWORD` in addition to TLS (ADR-009, issue #306). Before
  starting an approved multi-server cluster, provision the same scoped
  credentials to every peer through the operator-owned secret mechanism.

  The server fails closed if a configured route peer presents the wrong
  credentials.
  Single-host deployments (no configured routes) are unaffected at runtime.

The checked-in config defines leaf and cluster listeners even when no remote
peers are configured. That does not remove the client-compatibility gate or
authorize publishing those listeners.

### 4c. Activation Is Blocked at the Current Pins

There is intentionally no live launch command here. After the client and leaf
compatibility gaps are repaired, an operator-approved deployment procedure must
bind an immutable NATS image or binary, explicit private listener addresses,
persistent JetStream storage, versioned credentials, and the deployment-owned
service manager. It must validate the candidate before activation and preserve
the exact rollback set. Until then, record NATS activation as unavailable
rather than substituting a permissive broker or treating a canary as complete.

### 4d. Configure Leaf Nodes (Multi-Host Only)

The checked-in server and leaf configurations use matching, account-scoped
user/password authentication in addition to TLS. Provision each leaf's
`NATS_LEAF_<ACCOUNT>_URL` as a complete
`nats+tls://leaf-<lowercase-account>:<encoded-password>@<approved-hub>:7422`
URL. Its password must match the hub's corresponding password variable;
percent-encode reserved URL characters. SYS has no remote or leaf credential.

This replaces the unsupported remote token declaration and the shared listener
credential. Migrate both sides together under operator approval; do not reuse
the old `NATS_LEAF_TOKEN`, `NATS_LEAF_USER`, or `NATS_LEAF_PASSWORD` interface.
Static validation uses public test credentials and does not verify deployed
secrets or prove connectivity. Activation remains blocked by section 4c.
See `docs/runbooks/add-new-host.md` and `docs/runbooks/enable-nats-auth.md` for
the certificate and credential flow.

---

## Step 5: Configure Nomad (Optional Multi-Host Infrastructure)

The repository retains Nomad configuration for explicitly operated multi-host
infrastructure. It is not the current general agent scheduler: the checked-in
Myrmidons schema reserves a `nomad` discriminator but current runtime
scheduling implements `local` and `docker`, and
[ADR-023](adr/023-defer-multi-host-nomad-scheduling.md) remains Proposed.
Skip this section for the supported local or Docker reconciliation path.

### 5a. Use the Operator-Owned Activation Route

The canonical Nomad configs are at:

- `configs/nomad/server.hcl` — Primary cluster controller
- `configs/nomad/client.hcl` — Worker node config

Activation is a protected infrastructure operation because the repository
cannot determine the live network addresses, filesystem ownership, TLS state,
ACL principals, or container runtime socket. Obtain operator approval and bind
those values from live state before starting either agent. In particular:

1. Set `NOMAD_SERVER_IP` and `NOMAD_ADVERTISE_ADDR` from the approved network;
   do not copy historical host addresses from documentation.
2. Provision an operator-owned writable render directory outside the checkout,
   then run `just render-nomad-configs <operator-owned-writable-directory>`.
   Nomad does not expand the source HCL's environment placeholders itself.
3. Validate the rendered HCL and effective TLS/ACL settings before activation.
4. Use separate persistent data directories for server and client. If the
   client uses rootless Podman, resolve and verify that user's live API socket
   rather than assuming `/var/run/podman` exists.
5. Start the server through the operator-owned service or container definition,
   bootstrap its ACL system exactly once, store the management token in the
   approved secret manager, and issue a scoped node token.
6. Supply the scoped `NOMAD_TOKEN` to the client through the approved secret
   channel, start it through its operator-owned definition, and verify
   registration with an authenticated `nomad node status` readback.

There is intentionally no generic `podman run` command here: without the
operator-owned mounts, credentials, ownership, and socket mapping it would be
an unsafe and non-executable deployment recipe.

---

## Step 6: Select the Keystone-Owned Development Path

Odysseus does not proxy a live submodule `justfile`: a dirty or replaced child
recipe would execute outside the component's review boundary. Use an isolated
checkout of the exact Keystone revision, read its current `AGENTS.md` and
README, and invoke only the component-owned development path authorized there.
Starting a development container does not start a production transport daemon
or prove NATS connectivity.

---

## Step 7: Start Agamemnon (Control Plane)

Agamemnon is the central orchestration engine. It coordinates planning, reconciliation, and HMAS (Hierarchical Multi-Agent System) orchestration.

The root repository does not expose a generic Agamemnon launcher. Such a
launcher cannot select an authorized NATS identity, transport policy, or
deployment target. Use the deployment path owned by
`control/Agamemnon/README.md` only after you configure the canonical NATS
authentication policy in [`runbooks/enable-nats-auth.md`](runbooks/enable-nats-auth.md).

After an operator starts the service, verify the documented health contract:

```bash
AGAMEMNON_URL=http://localhost:8080
curl --fail --silent --show-error "${AGAMEMNON_URL}/v1/health" |
  python3 -c 'import json,sys; assert json.load(sys.stdin).get("status") == "ok"'
```

---

## Step 8: Deploy Initial Agent Fleet (Myrmidons)

The Myrmidons repository contains declarative YAML manifests describing desired
agent state. At the current pin it is a dataset package and does not expose an
`apply` recipe; Odysseus therefore has no `apply-all` wrapper. Do not infer that
the authored dataset matches live reconciler state, and do not apply it during
ordinary setup.

If desired state must be reconstructed, first query the live Agamemnon
reconciler, confirm that no conflicting task is active, and obtain explicit
operator approval for the exact dataset and effects. Then follow the
version-matched reconciler procedure in the pinned Agamemnon checkout:

```bash
cd provisioning/Myrmidons
just --list

cd ../../control/Agamemnon
find tools/reconciler -maxdepth 2 -type f -print
```

If no compatible, documented procedure is present, stop and escalate rather
than inventing a wrapper or treating an unavailable reconciliation as success.

An approved reconciler run must submit desired state through the Agamemnon API
and verify convergence. Runtime creation uses each agent's explicit `local` or
`docker` deployment type; it does not implicitly create Nomad jobs.

Monitor agent startup:

Query Agamemnon with the reconciler's documented status command and compare the
result with the authored desired state. Nomad status is relevant only when an
operator has separately enabled the optional Nomad path in Step 5.

---

## Step 9: Hermes Activation Boundary

The pinned Hermes service accepts signed HTTP webhooks, maps supported GitHub,
Slack, and third-party events, and publishes them to NATS. It does not implement
outbound delivery or email handling.

The root repository does not expose a generic Hermes launcher. At the current
pins, Hermes does not apply its constructed TLS context to the NATS publisher,
so starting it against the canonical authenticated broker cannot establish the
required transport identity. First repair and integrate that compatibility gap,
then follow the version-matched deployment and health procedure in
`infrastructure/Hermes/README.md`. Until then, report Hermes activation as
unavailable; do not substitute a plain-NATS listener.

---

## Step 10: Argus Activation Boundary

Argus provides metrics, logging, and dashboards via Prometheus, Loki, and Grafana.

Argus activation is unavailable through the current gitlink pin. Its pinned
`start` recipe generates `configs/nginx/htpasswd`, while the pinned Compose
stack mounts `secrets/htpasswd`; delegating to it would mutate local state
without establishing a runnable credential boundary. The root
`just argus-start` compatibility entry point therefore exits before invoking
the component or container runtime.

A later Argus revision contains a candidate repair, but it is not part of this
exact integration point. Review and integrate the fixed Argus commit first,
then use that version's component-owned setup, activation, and health
procedure. Do not copy credentials or commands across revisions.

---

## Step 11: Verification

Collect evidence for each deployed surface. No single command below proves the
entire ecosystem is operational.

### 11a. Check Repository State

```bash
just status
```

This shows Git status across the root and initialized submodules. It does not
query service health.

### 11b. Verify Network Connectivity

Confirm all hosts can reach each other over Tailscale:

```bash
sudo tailscale ping <peer-tailscale-ip>
```

Skip this check for local or CI deployments with no operator-approved
multi-host mesh.

### 11c. Check Optional Nomad Job Status

```bash
nomad status
```

Run this check only for an explicitly operated Nomad deployment. For the
current `local` and `docker` agent paths, use Agamemnon's reconciler status
instead.

### 11d. Verify NATS JetStream

This operator probe is unavailable at the current pins: the canonical policy
has no dedicated least-privilege diagnostic identity, and the pinned server
image does not provide the NATS CLI. Do not borrow Hermes, Agamemnon, Nestor, or
another service's credentials for an operator check.

After a dedicated diagnostic identity and its exact subject/API permissions are
approved, integrated, and deployed, use the deployment-owned probe procedure.
Record an allowed JetStream read and a denied out-of-scope operation against the
bound listener, then remove or disable any temporary diagnostic access. Until
that exists, report the JetStream authorization probe as unavailable rather
than substituting a credential or a permissive local broker.

Compare the live streams and consumers with the checked-in subject setup and
the services you actually started; do not infer deployment from a fixed stream
name list.

### 11e. Test Nestor (Research Service)

If Nestor was started separately, use its read-only health endpoint:

```bash
curl --fail --silent --show-error "$NESTOR_URL/v1/health" |
  python3 -c 'import json,sys; assert json.load(sys.stdin).get("status") == "ok"'
```

A successful response proves only that the bound HTTP service reports healthy.
Do not create a persistent research intake as a routine deployment probe. Any
write-path canary requires separate approval for the exact environment and
payload plus a version-matched cleanup/readback procedure. The pinned Nestor
service does not run a research-worker pool.

---

## Step 12: Production Hardening

This section is a routing checklist, not authorization to change a live
environment. For each service selected for production, the operator must bind
the exact target and current readback, approve the proposed delta and effects,
and record a tested rollback path. If any of those inputs or a version-matched
component procedure is unavailable, stop before mutation.

### 12a. Enable TLS and NATS Authentication

Nomad ACLs are already enabled in `configs/nomad/server.hcl` and `client.hcl`
(issue #196). An operator-owned activation must bootstrap the server ACL once,
store the management token, and issue scoped client tokens as described in
Step 5.

NATS TLS encryption and mutual-TLS authentication are enabled in the checked-in
`configs/nats/server.conf`; ADRs 008 and 010 remain Proposed design context.
Ensure role certs are provisioned and all clients are configured
before starting NATS (see step 4a and `docs/runbooks/enable-nats-auth.md`). If
Nomad TLS requires a canonical config change, obtain human coordination
approval before editing `configs/nomad/`, then render and validate a new
operator-owned deployment copy.

### 12b. Configure Persistent Storage

For each selected stateful service, use its version-matched deployment
procedure to compare the current storage attachment with the proposed durable
target. Record ownership, retention, migration, backup verification, and
rollback before an operator approves the exact change. Do not infer a volume or
cloud-storage target from this repository.

### 12c. Set Up Monitoring Alerts

After a repaired Argus commit is integrated, use that version's procedure to
discover existing alert rules and destinations. An operator must approve the
exact rule and notification delta plus rollback before it is applied; the root
repository does not select recipients or mutate Grafana.

### 12d. Enable Audit Logging

If the selected deployment requires durable orchestration records, use the
exact Agamemnon version's procedure to inventory its store and logging state,
then have the operator approve a scoped destination, retention policy, secret
boundary, migration, and rollback. Its default in-memory store is not a durable
decision log. GitHub audit logs cover GitHub-side events only and must not be
represented as a complete record of Agamemnon orchestration decisions.

### 12e. Secure Tailscale

For an explicitly selected multi-host mesh, the network operator owns the ACL
policy. Use current vendor documentation and an administrative readback to
bind the exact peers and ports, review the proposed least-privilege delta and
rollback, and obtain approval before any policy change. The
`docs/runbooks/add-new-host.md` checklist is a fail-closed routing guide, not
deployment authority.

---

## Troubleshooting

### Services Fail to Start

For container-managed services, check the actual container name reported by
the component's status recipe. For native services such as Hermes, inspect the
foreground process output or run the component health recipe instead.

```bash
podman logs <container-name>
```

### Network Connectivity Issues

This route applies only to an operator-enabled multi-host deployment. Have the
network operator verify current peer state through the approved administrative
readback. If re-enrollment is required, use the current vendor procedure and an
approved secret-input mechanism; never put an auth key in command arguments,
environment variables, shell history, or repository files.

### Agents Not Spawning

For the current `local` and `docker` paths, inspect the Agamemnon reconciler
response and Agamemnon process logs first. Compare the returned agent state to
the submitted Myrmidons manifest; a failed or unavailable wrapper is not a
successful apply.

For an operator-enabled Nomad deployment only, verify the Nomad client is
registered:

```bash
nomad node status
```

If no clients appear, inspect the operator-owned client service, its scoped
token, rendered config, and runtime socket. Restart it only through that
deployment's approved service manager.

### NATS Cluster Not Forming

This check applies only to an operator-enabled multi-host NATS cluster. Check
NATS logs and verify all hosts use matching cluster credentials and routes:

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
