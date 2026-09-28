# HomericIntelligence System Architecture

> **Post-migration architecture.** This document reflects the state after
> ADR-006 was implemented. ai-maestro has been replaced by native
> HomericIntelligence components and is fully removed from the meta-repo
> (no entry in `.gitmodules`, no `infrastructure/ai-maestro/` directory).
> See [ADR-006](adr/006-decouple-from-ai-maestro.md).
>
> **Current state versus proposals.** Only ADRs marked Accepted are binding
> architectural decisions. ADRs 008–010, 012–014, 017–022, and 024 are Proposed
> at this revision. ADR-023 is reserved but absent. The role-addressed mesh,
> end-to-end pipeline, state mapping,
> SLO targets, and distributed Hephaestus material below describe proposed or
> partially implemented target state, not proof of deployment. Checked-in
> service interfaces, schemas, configuration, and verified live readbacks are
> the authorities for current behavior.

---

## Overview

HomericIntelligence is a distributed agent mesh built from purpose-built,
loosely-coupled components. Coordination is owned by Agamemnon, and Keystone
owns an in-process lock-free MessageBus plus an optional NATS bridge. Components use
the interfaces their pinned implementations expose: NATS subjects where
implemented, and Agamemnon's REST API for integrations such as Telemachy and
Charybdis. Do not assume every integration traverses Keystone.

Odysseus is the meta-repo and user-facing hub. It holds Architecture Decision
Records, runbooks, canonical configs, and references every other repository as
a git submodule. The checked-in `.gitmodules` currently defines 15 component
gitlinks, for 16 canonical repositories including Odysseus. Odysseus itself
does not own component service implementations; it does own integration
scripts, E2E harnesses, and the operator console used to coordinate them.

The [Fleet web application](../web/README.md) lives in `web/`:
the initial implementation provides work ownership, worker, live
message observation, GitHub pipeline projection, scoped session controls, and
private agent requests. Agamemnon retains
orchestration authority. The remaining
conversation-history/intake flows and infrastructure acceptance gates are tracked in the
[Fleet implementation plan](homeric-fleet-plan.md).

The web backend uses supported management APIs and Keystone observation
subscriptions. Task dispatch remains on Keystone's canonical role subjects;
HTTP management calls do not establish a second task queue.

The laptop dashboard opens directly on loopback without a UI token, login,
session cookie, or session expiry. Local-machine access is its trust boundary.
Host, Origin, and cross-site checks remain required; writes need a matching
Origin. The dashboard remains visible during reconnects,
marks stale observations, and never automatically replays writes. Component
credentials remain on the backend; command enablement, canonical admission,
and private worker attachment checks remain required. Remote browser access
requires a separate TLS/authentication deployment.

---

## Component Inventory

| Component | Category | Role |
|-----------|----------|------|
| **Odysseus** | meta | User interface, observability hub, and meta-repo. Bidirectional with user. Consumes Argus dashboards. |
| **Agamemnon** | control | Planning, coordination, and HMAS orchestration (L0–L3). Its default store is in-memory; GitHub Issues write-through is optional. GitHub Projects is not its backing store. Agamemnon does not perform research or expose a user UI. |
| **Nestor** | control | Thin C++ intake/status/dispatch service for research. Pinned source implements the in-memory `POST /v1/research` path plus `hi.research.{id}` and role-addressed research publication; LLM research/interviewing/ideation remains outside the C++ service. Source behavior is not proof of a deployed or restart-durable end-to-end flow. |
| **Keystone** | transport | C++ transport library with an in-process lock-free MessageBus and an optional NATS JetStream bridge. Callers that adopt Keystone resolve its backend through configuration; REST services and direct NATS clients do not pass through it. |
| **Hermes** | infrastructure | Inbound webhook-to-NATS bridge. The pinned service validates signed HTTP webhooks and publishes supported events to NATS; it has no outbound-delivery or email implementation. |
| **Argus** | infrastructure | Observability: Prometheus metrics, Loki log aggregation, Grafana dashboards, Promtail scraping. Feeds Odysseus dashboards. |
| **AchaeanFleet** | infrastructure | OCI base and vessel images for AI-agent runtimes. It does not own every HomericIntelligence service image. Its primary mesh Compose file uses `agamemnon-frontend` and `agent-backend`; the worker Compose file uses `homeric-mesh`. |
| **Myrmidons repo** | provisioning | Versioned desired-state dataset with agent templates and container specs. Its pinned schema enumerates `local`, `docker`, and a future-reserved `nomad` discriminator; current runtime scheduling implements `local` and `docker`. A separately approved, compatible Agamemnon reconciler would apply selected state. The pinned dataset is not proof of live state and has no `apply` recipe. Multi-host scheduling via Nomad remains target work (see [Proposed ADR-023](adr/023-defer-multi-host-nomad-scheduling.md)). |
| **Telemachy** | provisioning | Declarative workflow engine and work-description source. Pinned source implements workflow-YAML registration as GitHub epics with child issues and publication of `hi.pipeline.epic.*.registered`. That component-local implementation is not proof of deployed writer exclusivity, durable delivery, or the complete ADR-013 integration target. |
| **Proteus** | ci-cd | CI/CD. Dagger TypeScript pipelines build AchaeanFleet images. The pinned revision accepts AchaeanFleet `image-pushed` events and sends `agamemnon-apply` to Myrmidons, but the pinned Myrmidons revision has no receiver or `apply` recipe, so that dispatch does not currently reconcile desired state. |
| **Myrmidons (workers)** | workers | Proposed ADR-013 targets a pull-based worker pool on role-addressed queues `hi.myrmidon.{domain}.{role}.task.>` with domain-crossed HMAS roles ([proposal](adr/013-hmas-mesh-wire-contracts.md)). Verify reconciler and worker state before treating that pool as deployed. Multi-host clustering via Nomad is also only proposed for a future phase (see [Proposed ADR-023](adr/023-defer-multi-host-nomad-scheduling.md)). |
| **Scylla** | testing | AI agent ablation benchmarking; evaluates agent architectures across tiered configurations (T0–T6). |
| **Charybdis** | testing | Chaos and resilience testing. Injects faults via Agamemnon `/v1/chaos/*` endpoints. |
| **Athena** | agentic | Agent-host plugin and skill distribution for Claude Code, Codex, and Pi. Owns the `athena@Athena` plugin manifests, skills, and supporting assets; depends on Hephaestus under Accepted ADR-016. |
| **Mnemosyne** | shared | Knowledge store and retrieval backend used by Athena's `advise` and `learn` skills. It is neither a plugin marketplace nor an agent-template registry. |
| **Hephaestus** | shared | Python library and automation runtime; Fleet Codex app-server adapter, private worker journal, execution supervision, workspace and issue-stage execution. It does not own plugin manifests or the skills registry. |
| **Odyssey** | research | Standalone Mojo ML training framework. Reproduces classic AI/ML research papers; provides reusable tensor ops, autograd, and training infrastructure. Not integrated with the agent mesh; implementations live entirely in-repo as Mojo libraries and executables. |
| ~~ai-maestro~~ | removed | Removed per [ADR-006](adr/006-decouple-from-ai-maestro.md). No submodule entry and no `infrastructure/ai-maestro/` directory. Do not reintroduce. |

---

## Network Topology

The explicitly operated multi-host configuration routes inter-host traffic
over **Tailscale**, a WireGuard mesh VPN. The active tailnet name and ACLs are
operator-owned live state; do not infer them from a historical hostname in
documentation. Tailnet membership does not by itself prevent a service from
binding a public interface. Every deployment must verify the service bind,
host firewall, tailnet ACL, and local/remote reachability before claiming
private-only exposure. If the required transport or reachability checks are
unavailable in an execution environment, record that limitation and rely on an
authorized environment rather than claiming deployment evidence.

Keystone callers can use its in-process MessageBus for local communication without
traversing the network. Other components use their repository-owned REST or
direct NATS integrations.

Fleet adds externally administered Slurm/Pyxis clusters through the proposed
[ADR 021](adr/021-fleet-execution-and-web-interface.md). Teleport/SSH establishes
authenticated allocation attachment for those clusters. It does not imply
compute-node access from a login-node tunnel. Login-node commands are transient;
the allocation-local Keystone gateway preserves canonical subjects and ACK
semantics. These cluster paths require execution and recovery canaries before use.

---

## System Diagram

This diagram combines established component ownership with target-state edges
from Proposed ADRs 013 and 020. It is a coordination view, not evidence of
current deployment or live end-to-end behavior.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                           USER                                      │
  └─────────────────────────────┬───────────────────────────────────────┘
                                │ bidirectional
                                ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                         Odysseus                                    │
  │        meta-repo · user interface · observability hub              │
  └────────────────┬───────────────────────────────┬────────────────────┘
                   │                               │
                   │ implemented intake route;       │ dashboards / alerts
                   │ deployment unproved
                   ▼                               ▼
  ┌────────────────────────────┐    ┌──────────────────────────────────┐
  │       Nestor        │    │          Argus            │
  │  intake · status · dispatch│    │  Prometheus · Loki · Grafana     │
  │  (research work is external)│   │  Promtail                        │
  └────────────────┬───────────┘    └──────────────────────────────────┘
                   │ [ADR-013 target] handoff
                   ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                      Agamemnon                               │
  │   HMAS L0–L3 · in-memory store · optional Issues write-through     │
  │   /v1/tasks  /v1/agents  /v1/chaos/*  /v1/workflows                │
  └─────────────────┬──────────────────────────────────────────────────┘
                    │ [ADR-013 target] dispatch via Keystone subjects
                    ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                    NATS JetStream                              │
  │   Direct clients · optional Keystone NATS bridge                    │
  └──────┬──────────────────────┬──────────────────────────────────────┘
         │ [ADR-013 target]                     │ [ADR-013 target]
         │ hi.myrmidon.pipeline.{role}.task.>   │ hi.myrmidon.research.{role}.task.>
         ▼                                      ▼
  ┌──────────────────────┐   ┌──────────────────────┐
  │  Pipeline myrmidons  │   │  Research myrmidons   │
  │  (pull, per-role     │   │  (pull, per-role      │
  │   durable consumers) │   │   durable consumers)  │
  └────────┬─────────────┘   └──────────────────────┘
           │ runs images from
           ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                        AchaeanFleet                              │
  │   AI-agent base/vessel images · homeric-mesh Podman network     │
  └──────────────────────────────────────────────────────────────────┘
           ▲ builds & pushes
  ┌──────────────────────────────────────────────────────────────────┐
  │                       Proteus                             │
  │   Dagger TypeScript · AchaeanFleet image-pushed relay            │
  └──────────────────────────────────────────────────────────────────┘

  External services ──► Hermes ──► NATS (supported webhook subjects) ──► consumers

  Myrmidons repo (GitOps YAML manifests) ──► Agamemnon API reconciliation
  Telemachy  ──► Agamemnon REST API; deployed registration handoff remains unproved
  Charybdis  ──► Agamemnon /v1/chaos/* (fault injection)
  Scylla     ──► ablation benchmarking (T0–T6 tiers)
  Athena     ──► public athena@Athena plugin; pinned revision has 14 routers
  Mnemosyne  ──► knowledge store/backend for Athena advise and learn
  Hephaestus ──► shared runtime utilities and automation support
  Odyssey    ──► standalone Mojo ML framework (paper reproductions, in-repo only)
```

---

## Proposed ADR-013 Pipeline Target

The following is the end-to-end target proposed by
[ADR-013](adr/013-hmas-mesh-wire-contracts.md). ADR-013 is still Proposed, so
this sequence is neither a deployed architecture claim nor current runtime
evidence. Several component-local pieces already exist in pinned source:
Nestor's in-memory intake/status and publications, Telemachy's epic/child
creation and registration publish, and Agamemnon's task state machine,
subscriptions, and unblocked-child delegation. Their existence does not prove
that this complete sequence is configured, durable, or running together:

```
 1. A user would submit a high-level task through Nestor's implemented intake
    route from an authorized client such as the target Odysseus console
       │  POST /v1/research (Nestor)
       ▼
 2. Nestor's pinned source would register the in-memory intake and publish to
    the research pool; restart-durable intake remains a separate gate
       │  hi.myrmidon.research.chief-architect.task.{id}
       ▼
 3. A research myrmidon would claim it, research the idea, interview the
    user, ideate extensions, and produce a researched brief
       │  hi.pipeline.interview.{intake_id}.question/.answer.{q_id}
       ▼
 4. Telemachy's pinned source would describe the work and register it in GitHub
    as an epic with child issues (task-list body, state:needs-plan)
       │  hi.pipeline.epic.{epic_key}.registered
       ▼
 5. Agamemnon's pinned state machine would submit the HMAS root
    (Pending → Decomposing) and dispatch a planning burst to the pipeline
    planner queue once the proposed integration is admitted
       │  hi.myrmidon.pipeline.chief-architect.task.{id}
       ▼
 6. A planner myrmidon would extend the epic into tasks/features/bugs/
    sub-tasks in GitHub, and Agamemnon would ingest the resulting brief
       │  POST /v1/briefs  →  L0–L3 HmasTask tree (Delegated)
       ▼
 7. Leaf tasks would be dispatched to the worker pool; myrmidons on mesh
    nodes would claim individual tasks and move the proposed state machine
       │  hi.myrmidon.{domain}.{role}.task.{id}   (claim = assignment)
       │  hi.tasks.{team}.{task}.started/completed/failed  (facts)
       ▼
 8. Each stage selects only the skills justified by its task; the item moves
    through implementation, PR review (state:implementation-go), and the
    dedicated merger stage
    A learning write requires separate authorization; otherwise record a no-write SKIP.
       │  child completion wakes blocked parents in Agamemnon
       ▼
 9. delegate_unblocked_children would dispatch each next burst until the
    epic's tree reaches Completed
```

In the proposed flow, interviews, escalations, and dashboards use the named
subjects shown above. Current control integrations also make explicit REST
calls to Agamemnon, including Telemachy workflow submission and Charybdis fault
injection. Keystone is a transport detail rather than a pipeline stage; it is
not the route for every current interaction. The target worker flow uses
AchaeanFleet images. Knowledge retrieval and preservation are contextual skill
choices, not mandatory wrappers around every task.

Under this proposal, interviews, escalations, and dashboards would flow back up
the same subjects, so each hop would be bidirectional. Role-addressed work and
lifecycle messages would flow **through** Keystone. Supported management
interfaces would provide resource inspection and commands, including
Odysseus's backend adapters with component credentials, without creating an
additional work queue. Keystone would remain a transport detail rather than a
pipeline stage.
The target workers would run AchaeanFleet images and request contextual advice
without turning missing/stale advice into a veto. Learning is not implicit task
authority: a worker writes a lesson only when that cross-repository effect is
separately authorized, and otherwise records a no-write SKIP.

This sequence is the integration target. Fleet acceptance must still establish
durable research intake, registration publication, claimed worker execution,
interviews, and real parent-planner wakeups together. Local consumer replay and
fixture tests alone do not establish the complete production flow; see the
[implementation gates](homeric-fleet-plan.md#9-implementation-sequence-and-release-gates).

## Fleet interfaces and state ownership

The Fleet changes are being integrated through separate component PRs. The
submodule pins remain the last approved integration point; source in a feature
branch or a local test does not establish a deployed service.

| Record or interface | Owner and storage | Odysseus behavior |
|---|---|---|
| Publishable requirements, plans and discussion | Work-repository GitHub issues | Link to the canonical issue and PR |
| Orchestration graph, claims, generations and command intent | Agamemnon's GitHub-backed records | Read `/v1/fleet` resources; submit supported management commands |
| Pipeline board and implementation labels | Derived GitHub Project; Hephaestus owns issue-stage labels | Display each source and its freshness separately |
| Desired pools and execution policy | Myrmidons Git manifests | Display configured and observed state separately |
| Conversations, pending requests, answers and execution evidence | Hephaestus private runtime storage | Read scoped private attachments or explicitly registered immutable output exports |
| Recovery command receipts | Private worker/adapter journals | Display outcomes; never authorize replacement work from a journal |
| Live message observations | Keystone observations; retained metrics/logs belong to Argus | Render bounded metadata and expose gaps; never consume work for visualization |
| Observation restart cache | Disposable Odysseus presentation copy in an optional private local directory | Restore sanitized historical rows only; no resources, source health, claims, or command authority |

Agamemnon's `fleetd` is an execution adapter. It carries durable controller
commands to workers and journals acknowledgments without becoming another
scheduler. Sessions sharing one provider process retain independent logical
agent identities, claims, workspaces and generations. Application-message
observations connect an item to its reported component, agent, host and stage;
assignment alone does not establish active execution.

### Bounded observation restart history

`FleetView` applies one metadata projection to live intake and validated history.
Its dedicated restore path preserves observation/receive times, ordering, bounded
deduplication identities, source-sequence state, and coverage counters. Restore
does not pass through live intake or populate controller resource collections.
The Observation history page reuses snapshot/SSE data and marks restored origin;
restored rows never count as live traffic or enable work controls.

`web/server/observation-history.mjs` owns the optional local file lifecycle.
The composition root acquires the exclusive loopback port, validates/restores the
cache, then enables HTTP-generated and attached observations. The writer holds
one active and one replaceable pending snapshot. It uses owner-only files,
file sync, atomic replacement, and directory sync before advancing the reported
persisted prefix. A five-second final-flush deadline cannot produce a later
success receipt. File identity is checked again before replacement.

The closed `hi/odysseus/observation-history/v1` format holds at most 250 rows,
1,000 derived identities, and 1,000 source-sequence entries in a 4 MiB file.
One capped temporary member bounds transient storage. The optional
`ODYSSEUS_OBSERVATION_HISTORY_DIR` is canonical, owner-only, outside source and
shared scratch, and local to one host. Port-specific filenames keep separate
loopback services independent. No database, new component service, or work
consumer is introduced. Argus retains long-term observability ownership.

Missing, unavailable, restored, pending, and partially retained history remain
distinct from live component health. Corrupt or unsafe cache files are preserved.
A leftover temporary member causes read-only recovery, not automatic takeover.
Before replacement, write failures preserve committed bytes; after replacement,
directory-sync failure preserves the readable file but reports uncertain
durability without advancing confirmation. Every start creates a new SSE epoch
and reports an observation gap. The cache cannot recover unobserved or already
lost traffic. See [the web runbook](../web/README.md#observation-history-across-restart)
for configuration, recovery, and rollback.

### Subordinate build ownership

The versioned `hi/fleet/build/v1` record identifies its tool worker, allocation
and generation under `build.allocation`. Odysseus projects these fields and the
opaque `build.snapshotWorkspace` identifier. The retained `parent` relationship
is shown separately; its agent, worker and generation do not become the child's
identity or establish current parent ownership. Invalid or conflicting identity
fields keep the item visible with ownership unavailable. Generic build-job
records retain their existing projection.

A typed build ID must use the controller's `build-` plus 64 lowercase hexadecimal
digits. A malformed ID is replaced by an opaque display-only key in a namespace
that controller resource IDs cannot use. The UI labels it as a display key with
identity unavailable; the original value and snapshot workspace are omitted.
Such a key cannot become command scope or establish ownership.

Controller status and `updatedAt` describe admission, authorization, cancellation
and terminal facts. They do not establish observed tool activity. The initial
typed protocol has no current activity observation, host placement or absolute
snapshot path; the web view reports those as unknown. It never joins a tool
allocation through provider workers, counts the build as an issue agent, or
creates message observations from a resource poll. Raw workspace paths, policy
bodies and grants remain outside the browser projection.

### Private approvals and questions

The local web backend supports `/api/requests` for one current session, worker
and generation. It first reads Agamemnon's supported session resource, then the
configured Hephaestus private Unix socket. Worker inventory must agree with the
canonical owner and current conversation turn before and after the read. Before
any private file access or socket attachment, the backend also reads the complete
Agamemnon session, execution and build-job collections. Every configured private
spool and worker-state root must be separate from every canonical local workspace,
including other workers' and retained workspaces. Missing records, incomplete
collections, unknown host identities or unresolved local paths disable private
access. `ODYSSEUS_EXECUTION_HOST` identifies this host using the controller's host
name; it defaults to the operating-system hostname. This initial path requires
private same-host attachment; remote private attachment remains a separate
transport gate.

A typed subordinate build, including a retained terminal record, keeps private
access disabled because this protocol cannot supply its protected host/path
placement. The backend returns only `reason: build_workspace_unresolved` beside
the existing unavailable response. The browser explains the condition and
retains the original command for explicit retry; it does not infer that an
earlier uncertain attempt was never delivered. Extra generic placement fields
cannot bypass this refusal. The separate producer/consumer contract required to
restore safe access is proposed in the Fleet plan's heavy-tools section.

The inventory read is a defensive projection of Agamemnon state, not a workspace
admission authority. Hephaestus must independently exclude all configured private
roots from future workspace mounts and retain those exclusions across restart.
Workers cannot rely on a prior web inventory check to admit a new workspace.

Command approvals display the actual pending command. File approvals require
matching file-change evidence from the worker's private `thread/read` adapter.
The displayed request fingerprint includes those changes; changed evidence
invalidates a pending web decision. Without matching evidence, acceptance is
disabled. Agent questions preserve provider question IDs and answer types.

The browser submits a stable command ID to `/api/commands`. The backend checks
current ownership and pending evidence again, writes the response to the private
input spool, and calls Agamemnon's session `respond` operation with an opaque
reference. Keystone carries the canonical command to the owning worker. Raw
commands, diffs, questions and answers never enter the dashboard observation
stream or GitHub orchestration metadata. An uncertain response retains its
original identity for explicit retry; controller acceptance does not prove that
the provider accepted or completed the operation.

### Retained command output

Hephaestus owns retained Codex command records. Its bounded export operation
produces an immutable `hi/fleet/session-output/v1` bundle and an exact-byte digest.
An operator can collect that bundle from an admitted VM worker and register its
private laptop path, digest and complete worker/session/generation identity.
Collection uses the separately approved host transport; Odysseus does not create
a remote worker socket, input spool, log server or new admission authority.

The web backend's `/api/session-output` reads only registered files. It verifies
private placement against complete canonical local workspace inventories, with
the backend checkout also protected. A complete inventory with no local workers
does not imply a missing inventory. Typed builds with unresolved placement still
disable private access. The reader validates the bounded closed schema, receipt,
item digests and exact scope before exposing plain text on explicit selection.
It fresh-reads the canonical session and distinguishes current from historical
ownership. Unavailable state stays explicit. Output is independent of command
enablement and excluded from shared snapshots, SSE, NATS and browser persistence.

This first profile includes observed completed command items only. Codex 0.153.4
supplies combined stdout/stderr with unknown provider truncation. Null output
does not prove an empty stream. Bundles report `complete: false`, collector
truncation and omission counts. They are execution evidence, not independent
review or task completion. Live progress remains the existing metadata flow;
live terminal output and full conversation history remain separate work.
See the [output collection runbook](../web/README.md#recorded-command-output).

### Durable research bootstrap

Nestor's legacy `/v1/research` keeps intake state in memory. It cannot satisfy
Fleet restart durability. The Nestor component PR adds an explicit, optional
GitHub-backed intake adapter while preserving that legacy interface. Its
proposed metadata namespace stores intake identity, request digest, creation
intent and confirmed work-issue reference in an operator-configured state
repository and branch. Publishable requirements belong to the work issue;
private interviews and provider authentication do not belong in Git metadata.

A GitHub Contents SHA transition reserves one issue-creation attempt. A crash or
lost response after reservation remains uncertain until reconciled; elapsed time
does not permit another create. This record is Nestor's research intake state,
not Agamemnon's task graph. Live GitHub concurrency and restart tests remain
required before this bootstrap can admit research work.

Odysseus now provides an opt-in Research intake form and backend proxy using
component credentials for `POST /v1/research/intakes` and the corresponding status
read. The browser retains publishable request content and identity before submission;
explicit retries preserve both, and read-only status checks compare the retained
request digest. Nestor credentials stay on the backend. Only a matching
`created` record with a confirmed issue receipt becomes a link in the UI.
This interface does not dispatch research workers or maintain another queue.
See the [API and recovery contract](research-intake-api.md). Local transport and
browser fixtures establish the interface behavior, not live GitHub admission.

The separately enabled import path submits only a confirmed intake ID and request
digest to Agamemnon's `/v1/fleet/research-intakes`. Agamemnon rereads Nestor and
owns the deterministic durable Pending L3 task and immutable provenance; import
does not dispatch work. Odysseus retains one explicit browser reference for
uncertain-response recovery. It creates no backend task queue or alternate issue.
The same browser lock coordinates import, retry and intake replacement; no reload
or reconnect automatically repeats a POST.

An independently enabled planned-issue action uses Agamemnon's registered work
repository projection and `/v1/fleet/issue-intakes` inspection/import interface.
It accepts an existing issue and an explicitly selected body/comment snapshot,
without requiring Nestor. Agamemnon owns neutral `issueIntake` provenance, the
native-identity task key and shared deduplication with research imports. Odysseus
keeps only a typed browser recovery reference and projects the neutral
`/api/tasks/{taskId}` status through the same owner checks. Import does not approve
a plan, dispatch a worker or acquire an issue-writer claim. Controller-side
pre-create fencing and positive uncertainty reconciliation remain necessary;
browser timeout or an empty status read cannot replace that authority.

Both import POSTs allow forty seconds in the BFF and forty-five in the browser,
including response body consumption. Read-only owner operations retain the
five-second BFF budget. An owned reader is cancelled and released on deadline or
failure; increasing the import budget does not extend unrelated Fleet polling.

Known-task reads validate intrinsic task/provenance identity, then compare the
exact raw Fleet owner and reread the relevant task fields. The bounded projection
excludes private content and workspace paths. This consistency check is not an
atomic snapshot or a new admission authority. Assignment, current claim, terminal
retained claim, manual resolution and fresh activity remain separate. A partial
read cannot mark all Agamemnon resources fresh or manufacture an execution link.
Only actual adapter HTTP request/response observations enter the existing flow
stream; worker-generation and activity predicates remain unchanged. Compatible
service deployment, live GitHub persistence/restart and worker admission still
require their separate acceptance evidence.

The Proposed ADR-013 target for Telemachy's initial Fleet registration path
requires a marked, pre-existing epic and an externally exclusive writer. A
local integration test passed the real producer's exact bytes through a private
JetStream broker into the native Agamemnon consumer, including lost publication
receipt, failed durable write, replay, restart, and parent wakeup. Its GitHub
service is a controlled fixture. This evidence does not establish deployment,
live GitHub writer fencing, or the complete research-to-implementation flow.

### First working agent

The immediate target is one real agent, with capacity one, that works on an
already-planned issue and is visible in Odysseus. Agamemnon owns registration,
durable admission, and the issue claim. Keystone and `fleetd` deliver the
admitted start and subsequent input. Hephaestus executes the model and tools
inside the qualified boundary. Odysseus displays the canonical owner, actual
activity, and observed message flow. A worker registration or conversation alone
does not demonstrate work. Research intake, build offload, cluster allocation,
and capacity experiments do not precede this target unless the issue needs them.

The first dashboard can show ownership and flow with session commands disabled.
The operator uses the existing admitted input and resolution interfaces. Private
UI input and request adapters require same-host paths; a laptop backend cannot
use a Linux guest path as a local spool or worker socket. Do not add cross-VM
spool transport as a prerequisite for this read-only view.

Hephaestus owns the connection between contained execution and worker admission.
A supervisor, attachment, or provider start does not authorize a session.
Admission must check the verified owned boundary and selected assignment. A real
model turn must use that boundary for normal tools before execution is qualified.

The first complete flow can use an operator. Retain the source changes and actual
checks, then obtain independent review. A completed provider turn does not complete
the canonical task. For contained work, an admitted cancel must confirm the exact
supervisor disposal before the operator submits a task resolution. Cancellation
stops the execution; the separate review decision determines the task outcome.
Agamemnon's existing manual resolution interface checks the current claim,
generation, inactive execution, cleanup evidence, and outstanding commands.
Confirmed cancellation releases Fleet execution capacity. The canonical task
claim remains for the separate resolution. Resolution persists the canonical
outcome before it records the matching Fleet decision.

The operator supplies the separate resolution credential and the real review
reference. The worker must not receive that credential. The retained decision
has `provenance: manual` and `verifiedApproval: false`. Odysseus can display that
decision after a task refresh; it does not submit the resolution. The source PR
and issue still follow their normal review, merge, and closure process. Automatic
review verification and the independently approved-work acceptance metric remain
separate requirements. A visible model turn alone does not meet this full flow.

### Execution and delivery gates

Hephaestus is adding a contained exec-server supervisor with immutable image and
workspace bindings, explicit resource limits, generation checks and independently
observed process/container cleanup. A normal pinned-provider conversation must
route every tool operation through that verified environment before admission
opens. Direct protocol probes and successful image startup do not establish
normal model routing. Existing non-Fleet integrations remain supported.

Each component PR must pass its local CI/CD, hosted checks and an Athena PR
review before merge. CI must exercise newly introduced runtime targets, including
their packaging and sanitizer requirements. Component merges do not update
Odysseus submodule pins automatically. Image build receipts, SBOMs and exported
artifact digests bind exact sources; deployment and the 12 + 48 + 48 real-work
acceptance experiment remain separate gates. Scheduled allocations stay disabled
until acceptance completes.

---

## Proposed ADR-013 Task-State Target

[ADR-013](adr/013-hmas-mesh-wire-contracts.md) §10 proposes that two state
systems cooperate through the following mapping. Pinned Agamemnon source
already contains its component-local state machine, task-event subscriptions,
and unblocked-child delegation; the cross-system mapping and deployed flow
remain target contracts, not deployed-state claims:

- **Implemented component-local Agamemnon TaskStateMachine** (per HMAS node):
  `Pending → Decomposing → Delegated → InProgress → Completed`, with
  `Escalated` (retry at parent layer) and `Failed` as exception paths. Pinned
  handlers consume task facts including `started`, `completed`, and `failed` to
  drive those local transitions and wake eligible children. This source fact
  does not itself validate the subject contract or prove live delivery.
- **Proposed Hephaestus `state:*` mapping** (per GitHub issue/PR):
  `state:needs-plan → state:plan-go/-no-go → state:implementation-go/-no-go`,
  plus `state:skip` on retry exhaustion. In the proposed ownership split, only
  Hephaestus automation would write these labels, only Agamemnon would write
  its own store, and workers would publish events.

The proposal targets leaves of ≲1 h active work without making that a hard
limit. A worker that overran ~1 h would checkpoint, register the remainder as
sub-tasks via `POST /v1/tasks/:id/split`, and complete its task as the first
slice. The proposed 5-minute heartbeats, 15-minute AckWait, and MaxDeliver=3
would detect worker death, not impose task length.

---

## Transport Layer (Keystone)

Keystone provides two backends to C++ callers that adopt its transport API:

| Backend | Scope | Transport |
|---------|-------|-----------|
| `core::MessageBus` | In-process | Lock-free local message bus |
| NATS bridge | Cross-process or cross-host | NATS JetStream through `nats.c` |

Those callers publish and subscribe to named subjects through the configured
backend; they do not address Keystone as a separate service. This library path
does not replace the direct NATS and REST integrations owned by other
components.

---

## Proposed ADR-013 Subject Target

All first-party subjects use the `hi.` prefix. The current routing summary and
component-authority links live in [`docs/nats-subjects.md`](nats-subjects.md).
Agamemnon's pinned OpenAPI and Hermes's pinned models/publisher own their
implemented subjects; the versioned dispatch schema owns `hi/v1` pipeline
packets. Proposed ADR-013 records candidate role-addressed and pipeline
subjects, not current publisher or consumer evidence.

[ADR-013](adr/013-hmas-mesh-wire-contracts.md) proposes the following target
overlay under the `hi.` namespace. The table includes older subject families
for migration context, but it is not proof of deployed publishers, subscribers,
consumer settings, or end-to-end behavior.

| Target subject pattern | Proposed publishers | Proposed subscribers | Target notes |
|-----------------|-----------|-------------|-------|
| `hi.myrmidon.{domain}.{role}.task.{task_id}` | Agamemnon, Nestor | Myrmidon pool (pull) | Role-addressed target; durable `myrmidon-{domain}-{role}`, AckWait 15 min, MaxDeliver 3 |
| `hi.myrmidon.{type}.{task_id}` | Agamemnon | — (legacy) | Proposed one-release dual-publish migration from the two-token legacy form |
| `hi.tasks.{team_id}.{task_id}.{verb}` | Workers, Agamemnon | Agamemnon, Odysseus, Argus | Proposed state-fact mapping; verbs `started`/`updated`/`completed`/`failed` |
| `hi.pipeline.interview.{intake_id}.{question\|answer}.{q_id}` | Research myrmidons ↔ Odysseus console | Console, interviewing worker | Proposed interview relay; GitHub issue comments as fallback |
| `hi.pipeline.epic.{epic_key}.registered` | Telemachy | Agamemnon (durable `agamemnon-epics`) | Pinned Telemachy source implements this publication and key grammar; durable subscriber ownership and deployed end-to-end delivery remain proposed |
| `hi.pipeline.>` | Odysseus, Argus, Hermes, Telemachy | Multiple (pub/sub) | Proposed fan-out and `homeric-pipeline` stream relationship |
| `hi.research.{id}` | Nestor | Nestor, console | Pinned Nestor source implements this publication grammar; deployed durable delivery and the broader status/compat relationship remain proposed |
| `hi.agents.>` | Agamemnon, Hermes | Argus (pub/sub) | Target agent-lifecycle relationship; accepted ADRs remain authoritative where applicable |
| `hi.logs.myrmidon.{domain}.{role}.{agent_id}` | Workers | Argus/Loki, Odysseus | Proposed structured worker logs carrying `exec_host` |
| `hi.logs.>` | All components | Argus/Loki, Odysseus (pub) | Proposed structured log forwarding relationship |

---

## Observability (Argus)

Argus provides the full observability stack:

- **Prometheus** — scrapes the checked-in Homeric exporter, JetStream consumer,
  Prometheus, Nomad, Atlas, and Alertmanager targets. The Homeric exporter polls
  the configured Agamemnon, Nestor, and NATS endpoints.
- **Loki + Promtail** — ingests the configured syslog, Hermes, and NATS log
  files. Atlas separately subscribes to `hi.logs.>` for NATS event viewing.
- **Grafana** — dashboards surfaced to Odysseus for user-facing visibility.
- **SLOs / SLAs** — Candidate service-level objectives for availability, task
  success, NATS event latency, reconnect time, and throughput are proposed in
  [ADR-012](adr/012-slo-sla-definitions.md). The pinned Argus tree has no
  dedicated SLO-rule file; verify its current `rules/` inventory and follow
  [runbooks/slo-alerting-rules.md](runbooks/slo-alerting-rules.md) before
  claiming or adding coverage. Latency and reconnect SLOs are gated on
  instrumentation that Argus does not yet emit (Proposed ADR-012, Tier 2).

Argus does not control or coordinate components; it is read-only with respect
to the rest of the system.

---

## Provisioning

### Myrmidons repo (GitOps)
YAML manifests in the Myrmidons repo describe the desired state of the agent
mesh. An operator-approved reconciliation binds the live state and exact
Myrmidons revision, then uses a compatible Agamemnon reconciler and REST API;
this architecture page does not authorize an apply.
The pinned Proteus revision can relay an AchaeanFleet `image-pushed` event as
`agamemnon-apply`, but the pinned Myrmidons revision has no receiving workflow
or `apply` recipe, so that relay is not a deployed reconciliation path. The
Myrmidons repo is the authoritative source of container specs and agent
templates (not Mnemosyne).

**Current schema:** Myrmidons admits `local`, `docker`, and a future-reserved
`nomad` deployment discriminator. Current runtime scheduling implements
`local` and `docker`; a live reconciler readback is required before claiming
either is active. Multi-host agent scheduling via Nomad is target work tracked in
[Proposed ADR-023](adr/023-defer-multi-host-nomad-scheduling.md).

### AchaeanFleet
AchaeanFleet defines and versions AI-agent base and vessel images; component
service repositories own their own service images. Its primary mesh Compose
file uses the `agamemnon-frontend` and `agent-backend` networks, while its
worker Compose file uses `homeric-mesh`. A new vessel is required only when a
containerized agent type needs a new image rather than an existing vessel.

### Proteus
CI/CD pipelines written in Dagger TypeScript build AchaeanFleet images. At the
pinned revision, Proteus reacts only to AchaeanFleet `image-pushed` events and
relays `agamemnon-apply` to Myrmidons. Because the pinned Myrmidons revision has
no corresponding receiver, this is not an every-submodule-merge deployment
path and does not replace an explicit Agamemnon reconciliation.

### Canonical Workflow Field Names

Telemachy's pinned workflow schema and `TaskSpec` own the YAML/Pydantic fields
authors write. Agamemnon's pinned OpenAPI owns the REST wire keys, and
Telemachy's client adapter owns the mapping between them. Documentation must
name the relevant layer explicitly and use the authored YAML names below for
workflow examples.

| YAML / Pydantic field | Agamemnon wire key | Deprecated — do NOT use |
|-----------------------|--------------------|-------------------------|
| `subject`             | `subject`          | `title`                 |
| `blocked_by`          | `blockedBy`        | `depends_on`            |
| `assign_to`           | `assigneeAgentId`  | —                       |

First-party Odysseus docs are guarded against the deprecated names by
`scripts/check-doc-field-drift.sh` (run via `just check-doc-field-drift`, part
of `just ci`). Submodule repos own their own equivalent guards.

---

## Research and Testing

### Odyssey — ML Research
Standalone Mojo ML training framework for reproducing classic AI/ML research
papers. Provides reusable tensor operations, autograd, and training
infrastructure in its own repository; it has no current NATS, Agamemnon, or
AchaeanFleet integration path.

### Scylla — Ablation Benchmarking
AI agent ablation benchmarking framework. Evaluates agent architectures across
tiered configurations (T0–T6). Its optional NATS adapter subscribes to
`hi.tasks.>` when enabled; the pinned implementation does not publish results
to Agamemnon task subjects.

### Charybdis — Chaos Testing
Injects faults and adverse conditions into the mesh via Agamemnon's
`/v1/chaos/*` endpoints. Does not bypass Agamemnon to reach components
directly.

---

## Agentic Infrastructure

### Athena
Agent-host plugin and skill distribution for Claude Code, Codex, and Pi.
Athena owns the `athena@Athena` plugin manifests, skills, and supporting assets.
It consumes Hephaestus as a library and automation dependency; Accepted
[ADR-016](adr/016-split-hephaestus.md) prohibits restoring the inverse
dependency or moving plugin ownership back into Hephaestus.

## Shared Infrastructure

### Mnemosyne
Team-knowledge memory store backing Athena's `advise` and `learn` skills.
Mnemosyne owns neither plugin/skill distribution nor agent templates; agent
specs live in the Myrmidons repo.

### Hephaestus
Python library and automation runtime consumed by HomericIntelligence
repositories and Athena. It includes changelog tooling, system-info helpers,
markdown utilities, the Fleet Codex app-server adapter, private worker journal,
execution supervision, and workspace/issue-stage execution. It does not own
agent-host plugin manifests or the skills registry.

### Odyssey
Standalone Mojo ML training framework for reproducing classic AI/ML research
papers. Provides a reusable shared library of SIMD-optimised tensor operations,
an autograd engine, and full training infrastructure — all implemented in Mojo.
Paper implementations live entirely in-repo as Mojo libraries and executables.
Odyssey is not integrated with the agent mesh (no NATS, no Agamemnon
REST API, no promotion path to AchaeanFleet); the only "agents" it uses are
Claude Code automation in `.claude/agents/` for development workflow.

---

## Adding a New Component

1. Identify the component type and owning repository, then follow that
   repository's current language, template, build, and security conventions.
2. Define any new wire subjects or contracts in their canonical schema owner
   and validate every producer and consumer together.
3. Keep service-container definitions with the service repository. Add an
   AchaeanFleet vessel only for an AI-agent image that AchaeanFleet owns.
4. Add Myrmidons desired-state only when the new component is a declaratively
   reconciled agent; services and libraries do not receive agent manifests by
   default.
5. Open an ADR when the component introduces a new architectural decision.
6. Merge and validate the component repository first. Only after explicit
   cross-repository integration approval, add its submodule or update its
   gitlink and this inventory in a separate Odysseus integration PR.
