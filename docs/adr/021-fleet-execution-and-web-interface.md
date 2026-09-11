# ADR 021: Extend Fleet Execution and Establish the Odysseus Web Application

**Status:** Proposed

---

## Context

Homeric Fleet must manage interactive and automated Codex work across a laptop,
externally administered M1/M2 Slurm clusters, and supported SSH hosts. These
environments cannot all use the existing Nomad/Tailscale deployment assumptions.

The architecture assigns coordination to Agamemnon, transport to Keystone, and
the user interface to Odysseus. Delivering the approved unified web application
requires extending Odysseus's earlier documentation-only application boundary.

This decision preserves accepted Nomad, Podman, and Tailscale decisions in their
existing environments. It does not declare deferred Nomad clustering implemented
or replace the established research and issue workflow.

## Decision

### Execution and resources

Use Slurm/Pyxis where the external cluster administrator controls scheduling.
Use existing SSH/Teleport configuration for authenticated submission, inspection,
and allocation attachment. Login-node operations remain transient; no permanent
login-node service is introduced. Verify compute-node reachability instead of
assuming that a login-node loopback tunnel reaches it.

Support conventional SSH hosts through capability-checked, persistent non-root
container workers. Report missing runtime, storage, resource enforcement, or
attachment capabilities as unsupported. Never silently substitute native execution.

Compare native macOS with a Linux VM on the laptop. The required combined
demonstration uses five Codex 0.153.4 runtimes and 108 active logical agents: one
laptop runtime with 12 conversations and two runtimes with 24 conversations on
each cluster. Each agent owns its claim, generation, workspace, permissions, and
conversation. Enforce aggregate runtime and explicit build-job limits; shared
conversations have no independent cgroups. Reserve supervision overhead and
separate laptop-tool capacity. Do not create a Slurm step per conversation or
silently reduce allocations.

Tool execution requires a separate verified boundary. Validate a contained
exec-server environment for each logical session while keeping authentication
and the provider process at runtime scope. Fence each environment by agent and
generation, disable local/default fallback, and use explicit singleton routing.
Resume must reconcile its stored binding before another turn. Tool process
cleanup and container/cgroup emptiness must be confirmed before releasing a
claim. A platform name, environment registration, or termination acknowledgment
does not prove these properties. Keep admission closed until the supported
backend passes actual filesystem, process, routing, and recovery tests.

### Coordination, persistence, and transport

Agamemnon owns admission, assignments, reconciliation, and recovery decisions.
Its `fleetd` execution adapter runs under a laptop LaunchAgent and manages
attachments and allocation operations without a separate scheduler or UI.

Require confirmed GitHub-backed orchestration writes before dispatch. Projects
are a rebuildable projection of issue-backed state. Reject memory-only operation
and incomplete hydration; fence the active writer before replacement execution.
Private append-only receipts support recovery without becoming another task
authority. Do not introduce a separate SQLite task/control store.

Nestor's legacy in-memory intake does not authorize Fleet research admission.
Add an explicit GitHub-backed bootstrap for intake identity, request digest,
creation intent and work-issue reference. Use deterministic metadata paths in an
operator-configured state repository and SHA-conditional transitions to grant
one issue-creation attempt. An uncertain create requires reconciliation; it does
not grant a new attempt. Requirements belong to the work issue and private
interviews remain outside Git metadata. Nestor owns only research intake state;
Agamemnon owns the resulting orchestration graph and worker admission.

Display Projects health, last rebuild attempt/success, implementation labels, and
current Fleet ownership as separate fields. A recent health read cannot refresh
the underlying rebuild or approve issue work. Stale controller reads disable
web controls and label the retained ownership explicitly.

Keystone carries canonical role work, versioned controls, acknowledgments, and
worker facts. Preserve durable consumer identity, progress renewal, redelivery,
and generation checks across allocation gateways. Observation clients never
consume or acknowledge work. Hephaestus retains issue-stage execution and its
authorized `state:*` labels.

### Odysseus application and activity

Odysseus owns the web frontend and backend for intake, interviews, workflows,
conversations, approvals, controls, evidence, and Argus dashboards. Initial access
is laptop-loopback-only, with authenticated sessions and validated browser origins.

Each item identifies its component, logical agent, role, stage, execution, worker,
host, allocation, generation, last observation, and blockers. Assignment and
observed execution remain distinct. A live system diagram displays actual
application-message observations with correlated identifiers and reconnect cursors.
Configured connections remain inactive until observed. Show sampling, gaps,
staleness, and disconnection; stop animations when observations stop. Exclude
payloads, prompts, secrets, and terminal bytes from telemetry. Do not infer
delivery or latency from unsynchronized clocks. Argus retains high-volume
observations outside GitHub.

Diagnostic terminal attachment passes through the backend. Codex app-server
messages remain authoritative for conversation control and approvals.

The authenticated web backend may read scoped pending requests and file-change
evidence through a configured private worker attachment. Bind session, worker,
generation, current thread/turn and request identity on every read and response.
File acceptance must also bind the displayed changes. If evidence is unavailable,
disable acceptance. Spool responses privately and dispatch only their references
through Agamemnon and Keystone. Never expose these private details as flow events.
The initial same-host Unix attachment does not establish remote private transport.

### Credentials and recovery

Each runtime independently establishes native Codex authentication and privately
owns its authentication storage. Disable nested subagents initially. Never
distribute copied refresh-token bundles. Laptop OpenBao manages Fleet-issued
identities and scoped infrastructure secrets; only `fleetd` accesses it. Apply
the five-day maximum only to credentials Fleet can expire or revoke. Display
actual issuer expiry or unknown status. Verify workspace and credential isolation.

Disconnected workers finish only admitted work. Reconcile inventory, receipts,
and durable claims before retrying; heartbeat loss alone cannot authorize
replacement. After acceptance, enable weekday 08:00 submission, 17:00 drain, and
an 18:00 America/Los_Angeles allocation termination deadline. Enforce termination
despite laptop disconnection and preserve truthful unfinished outcomes.

## Consequences

**Positive:**

- Extends execution without competing coordination or transport authorities.
- Provides one interface for ownership, activity, controls, and evidence.
- Preserves platform-specific enforcement and existing deployment decisions.

**Negative:**

- Adds transport, authentication, persistence, and browser integration work.
- Shared runtimes require tested permission isolation and measured account capacity.
- Real image builds, SBOMs, canaries, and failure/performance runs remain necessary.

**Neutral:**

- Proposed interfaces and partial implementation do not establish acceptance.
- Promotion requires independently observed 12 + 48 + 48 active agents doing real
  issue work. Queued or idle conversations do not count.

## References

- [Fleet implementation plan](../homeric-fleet-plan.md)
- [System architecture](../architecture.md)
- [ADR 003: Nomad scheduling](003-nomad-over-k8s.md)
- [ADR 006: Native coordination](006-decouple-from-ai-maestro.md)
- [ADR 011: Orchestration ownership](011-extract-python-orchestration-to-agamemnon.md)
- [ADR 013: Proposed HMAS wire contracts](013-hmas-mesh-wire-contracts.md)
