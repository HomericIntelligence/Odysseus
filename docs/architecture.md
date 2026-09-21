# HomericIntelligence System Architecture

> **Post-migration architecture.** This document reflects the state after
> ADR-006 was implemented. ai-maestro has been replaced by native
> HomericIntelligence components and is fully removed from the meta-repo
> (no entry in `.gitmodules`, no `infrastructure/ai-maestro/` directory).
> See [ADR-006](adr/006-decouple-from-ai-maestro.md).

---

## Overview

HomericIntelligence is a distributed agent mesh built from purpose-built,
loosely-coupled components. There is no central platform dependency:
coordination is owned by Agamemnon, transport is owned by
Keystone (BlazingMQ + NATS JetStream), and every other component
integrates through well-defined subjects rather than direct service calls.

Odysseus is the meta-repo and user-facing hub. It holds Architecture Decision
Records, runbooks, canonical configs, and references every other repository as
a git submodule. Its [Fleet web application](../web/README.md) lives in `web/`:
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
| **Agamemnon** | control | Planning, coordination, and HMAS orchestration (L0–L3). GitHub issues hold durable state; Projects is a derived view. Does not perform research or expose a user UI. |
| **Nestor** | control | Thin C++ intake/status/dispatch service for research. Accepts ideas (`POST /v1/research`), dispatches them to the research myrmidon pool, tracks status. Research, interviewing, and ideation run in research-pool myrmidons — never inside Nestor itself (LLM work never runs inside C++ services; see [ADR-013](adr/013-hmas-mesh-wire-contracts.md)). |
| **Keystone** | transport | Invisible transport layer. BlazingMQ for intra-host (<500 ns, >2 M msg/sec); NATS JetStream (nats.c v3.12.0) for cross-host over Tailscale. Components talk *through* Keystone, never *to* it. |
| **Hermes** | infrastructure | External message delivery bridge. Routes external-service events into NATS and delivers outbound messages to external services. |
| **Argus** | infrastructure | Observability: Prometheus metrics, Loki log aggregation, Grafana dashboards, Promtail scraping. Feeds Odysseus dashboards. |
| **AchaeanFleet** | infrastructure | Container image library. All agent and service images. Built by Proteus; run on the `homeric-mesh` Podman network. |
| **Myrmidons repo** | provisioning | GitOps source of truth. YAML manifests describe desired agent state; Agamemnon API reconciliation applies them. Also holds all agent templates and container specs. Multi-host scheduling via Nomad is deferred to a future phase (see [ADR-009](adr/009-defer-multi-host-nomad-scheduling.md)); currently supports `local` and `docker` deployment types only. |
| **Telemachy** | provisioning | Declarative workflow engine + work description and epic registration. Turns workflow YAML into GitHub epics with child issues and publishes `hi.pipeline.epic.*.registered` ([ADR-013](adr/013-hmas-mesh-wire-contracts.md)). Used programmatically by Agamemnon, Nestor, and research myrmidons. Not a user-facing service. |
| **Proteus** | ci-cd | CI/CD. Dagger TypeScript pipelines. Builds AchaeanFleet images; dispatches `agamemnon-apply` on merge. |
| **Myrmidons (workers)** | workers | The worker pool: all nodes that can run myrmidon agents. Pull-based from role-addressed queues `hi.myrmidon.{domain}.{role}.task.>` ([ADR-013](adr/013-hmas-mesh-wire-contracts.md)); myrmidon roles ARE the HMAS agentic roles at every level, crossed with domain (e.g. `research.chief-architect` vs `pipeline.chief-architect`). Multi-host clustering via Nomad is deferred to a future phase (see [ADR-009](adr/009-defer-multi-host-nomad-scheduling.md)). |
| **Scylla** | testing | AI agent ablation benchmarking; evaluates agent architectures across tiered configurations (T0–T6). |
| **Charybdis** | testing | Chaos and resilience testing. Injects faults via Agamemnon `/v1/chaos/*` endpoints. |
| **Mnemosyne** | shared | Skills marketplace / team-knowledge memory store for the `advise` and `learn` plugins only. Not an agent-template registry. |
| **Hephaestus** | shared | Shared automation and skills; Fleet Codex app-server adapter, private worker journal, execution supervision, workspace and issue-stage execution. |
| **Odyssey** | research | Standalone Mojo ML training framework. Reproduces classic AI/ML research papers; provides reusable tensor ops, autograd, and training infrastructure. Not integrated with the agent mesh; implementations live entirely in-repo as Mojo libraries and executables. |
| ~~ai-maestro~~ | removed | Removed per [ADR-006](adr/006-decouple-from-ai-maestro.md). No submodule entry and no `infrastructure/ai-maestro/` directory. Do not reintroduce. |

---

## Network Topology

Established mesh inter-host traffic flows over **Tailscale** — a WireGuard mesh VPN. The
mesh name is `tail8906b5.ts.net`. No inter-host port is exposed to the public
internet; every service assumes Tailscale reachability for cross-node
communication.

Fleet adds externally administered Slurm/Pyxis clusters through the proposed
[ADR 021](adr/021-fleet-execution-and-web-interface.md). Teleport/SSH establishes
authenticated allocation attachment for those clusters. It does not imply
compute-node access from a login-node tunnel. Login-node commands are transient;
the allocation-local Keystone gateway preserves canonical subjects and ACK
semantics. These cluster paths require execution and recovery canaries before use.

Intra-host communication uses BlazingMQ (via Keystone) and does not
traverse the network.

---

## System Diagram

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
                   │ research requests             │ dashboards / alerts
                   ▼                               ▼
  ┌────────────────────────────┐    ┌──────────────────────────────────┐
  │       Nestor        │    │          Argus            │
  │  research · ideation       │    │  Prometheus · Loki · Grafana     │
  │  Telemachy workflows       │    │  Promtail                        │
  └────────────────┬───────────┘    └──────────────────────────────────┘
                   │ handoff
                   ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                      Agamemnon                               │
  │   HMAS L0–L3 · issue-backed state · derived Projects view          │
  │   /v1/tasks  /v1/agents  /v1/chaos/*  /v1/workflows                │
  └─────────────────┬──────────────────────────────────────────────────┘
                    │ dispatch (via Keystone NATS subjects)
                    ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Keystone                                 │
  │   BlazingMQ (intra-host) · NATS JetStream (cross-host/Tailscale)   │
  └──────┬──────────────────────┬──────────────────────────────────────┘
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
  │   container image library · homeric-mesh Podman network         │
  └──────────────────────────────────────────────────────────────────┘
           ▲ builds & pushes
  ┌──────────────────────────────────────────────────────────────────┐
  │                       Proteus                             │
  │   Dagger TypeScript · builds images · dispatches agamemnon-apply │
  └──────────────────────────────────────────────────────────────────┘

  External services ──► Hermes ──► NATS (hi.pipeline.>) ──► internal consumers

  Myrmidons repo (GitOps YAML manifests) ──► Agamemnon API reconciliation
  Telemachy  ◄── used by Agamemnon + Nestor programmatically
  Charybdis  ──► Agamemnon /v1/chaos/* (fault injection)
  Scylla     ──► ablation benchmarking (T0–T6 tiers)
  Mnemosyne  ──► advise/learn plugins only
  Hephaestus ──► shared utilities, skills registry (all repos)
  Odyssey    ──► standalone Mojo ML framework (paper reproductions, in-repo only)
```

---

## Pipeline Flow

The full HMAS pipeline, end to end (wire contracts in
[ADR-013](adr/013-hmas-mesh-wire-contracts.md)):

```
 1. User submits a high-level task via the Odysseus console
       │  POST /v1/research (Nestor)
       ▼
 2. Nestor registers the intake and dispatches to the research pool
       │  hi.myrmidon.research.chief-architect.task.{id}
       ▼
 3. A research myrmidon claims it: researches the idea, INTERVIEWS the
    user (console live, GitHub issue comments as fallback), ideates
    extensions, and produces a researched brief
       │  hi.pipeline.interview.{intake_id}.question/.answer.{q_id}
       ▼
 4. The work is described via Telemachy and registered in GitHub
    as an epic with child issues (task-list body, state:needs-plan)
       │  hi.pipeline.epic.{epic_key}.registered
       ▼
 5. Agamemnon submits the HMAS root (Pending → Decomposing) and
    dispatches a planning burst to the pipeline planner queue
       │  hi.myrmidon.pipeline.chief-architect.task.{id}
       ▼
 6. A planner myrmidon extends the epic into tasks/features/bugs/
    sub-tasks in GitHub; the resulting brief is ingested
       │  POST /v1/briefs  →  L0–L3 HmasTask tree (Delegated)
       ▼
 7. Leaf tasks are dispatched to the worker pool; myrmidons on mesh
    nodes claim individual tasks and move the state machine
       │  hi.myrmidon.{domain}.{role}.task.{id}   (claim = assignment)
       │  hi.tasks.{team}.{task}.started/completed/failed  (facts)
       ▼
 8. Each worker: advise (before) → implement → PR → review gate
    (state:implementation-go) → merge → learn (after)
       │  child completion wakes blocked parents in Agamemnon
       ▼
 9. delegate_unblocked_children dispatches the next burst until the
    epic's tree reaches Completed
```

Interviews, escalations, and dashboards flow back up the same subjects, so
each hop is bidirectional. Role-addressed work and lifecycle messages flow
**through** Keystone. Supported management interfaces provide resource inspection
and commands, including Odysseus's backend adapters with component credentials.
They do not create an additional work queue. Keystone is a transport detail,
not a pipeline stage. All workers
run AchaeanFleet container images and integrate advise-before / learn-after
around every task.

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

Agamemnon's `fleetd` is an execution adapter. It carries durable controller
commands to workers and journals acknowledgments without becoming another
scheduler. Sessions sharing one provider process retain independent logical
agent identities, claims, workspaces and generations. Application-message
observations connect an item to its reported component, agent, host and stage;
assignment alone does not establish active execution.

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

Telemachy's initial Fleet registration path requires a marked, pre-existing
epic and an externally exclusive writer. A local integration test has now passed
the real producer's exact bytes through a private JetStream broker into the
native Agamemnon consumer, including lost publication receipt, failed durable
write, replay, restart and parent wakeup. Its GitHub service is a controlled
fixture. This evidence does not establish live GitHub writer fencing or the
complete research-to-implementation flow.

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

## Task State Machine

Two state systems cooperate, mapped one-to-one in
[ADR-013](adr/013-hmas-mesh-wire-contracts.md) §10:

- **Agamemnon TaskStateMachine** (per HMAS node):
  `Pending → Decomposing → Delegated → InProgress → Completed`, with
  `Escalated` (retry at parent layer) and `Failed` as exception paths.
  Transitions are driven by NATS facts: worker `started` → InProgress,
  `completed` → Completed (+ wake blocked children), `failed` → Failed.
- **Hephaestus `state:*` labels** (per GitHub issue/PR):
  `state:needs-plan → state:plan-go/-no-go → state:implementation-go/-no-go`,
  plus `state:skip` on retry exhaustion. Only Hephaestus automation writes
  these labels; only Agamemnon writes its own store; workers publish events.

Task sizing: leaves are planned to ≲1 h of active work. There is no hard
limit — a worker that overruns ~1 h checkpoints (commit/push + progress
comment), registers the remainder as sub-tasks via `POST /v1/tasks/:id/split`,
and completes its task as the first slice. Leases (5-min heartbeats,
15-min AckWait, MaxDeliver=3) detect worker death only, never task length.

---

## Transport Layer (Keystone)

Keystone provides two transport backends, selected by deployment scope:

| Backend | Scope | Latency | Throughput | Protocol |
|---------|-------|---------|------------|----------|
| BlazingMQ | Intra-host | <500 ns | >2 M msg/sec | In-process / shared memory |
| NATS JetStream | Cross-host | Network-bound | High | nats.c v3.12.0 over Tailscale |

Components publish and subscribe to named subjects. They never hold a reference
to Keystone itself; the transport is resolved at startup via configuration.

---

## NATS Subject Schema

All subjects use the `hi.` namespace prefix.

See [ADR-013](adr/013-hmas-mesh-wire-contracts.md) for consumer settings,
payload envelopes, and migration notes.

| Subject pattern | Publishers | Subscribers | Notes |
|-----------------|-----------|-------------|-------|
| `hi.myrmidon.{domain}.{role}.task.{task_id}` | Agamemnon, Nestor | Myrmidon pool (pull) | Role-addressed work queues; durable `myrmidon-{domain}-{role}`, AckWait 15 min, MaxDeliver 3 (ADR-013) |
| `hi.myrmidon.{type}.{task_id}` | Agamemnon | — (legacy) | Two-token legacy form; dual-published for one release, then removed |
| `hi.tasks.{team_id}.{task_id}.{verb}` | Workers, Agamemnon | Agamemnon, Odysseus, Argus | State facts; verbs `started`/`updated`/`completed`/`failed` (`started` added by ADR-013) |
| `hi.pipeline.interview.{intake_id}.{question\|answer}.{q_id}` | Research myrmidons ↔ Odysseus console | Console, interviewing worker | Interview relay; GitHub issue comments as fallback |
| `hi.pipeline.epic.{epic_key}.registered` | Telemachy | Agamemnon (durable `agamemnon-epics`) | Epic trigger; `epic_key = {repo_slug}-{issue_number}` |
| `hi.pipeline.>` | Odysseus, Argus, Hermes, Telemachy | Multiple (pub/sub) | Fan-out; Hermes bridges external events here; stream `homeric-pipeline` |
| `hi.research.{id}` | Nestor | Nestor, console | Research status/compat subject (dispatch rides `hi.myrmidon.research.*`) |
| `hi.agents.>` | Agamemnon, Hermes | Argus (pub/sub) | Agent lifecycle events |
| `hi.logs.myrmidon.{domain}.{role}.{agent_id}` | Workers | Argus/Loki, Odysseus | Structured worker logs; payloads carry `exec_host` |
| `hi.logs.>` | All components | Argus/Loki, Odysseus (pub) | Structured log forwarding |

---

## Observability (Argus)

Argus provides the full observability stack:

- **Prometheus** — scrapes metrics from Agamemnon, Nestor, Keystone, Hermes,
  and Myrmidon workers.
- **Loki + Promtail** — aggregates structured logs from all components via
  `hi.logs.>`.
- **Grafana** — dashboards surfaced to Odysseus for user-facing visibility.
- **SLOs / SLAs** — Service-level objectives for availability, task success,
  NATS event latency, reconnect time, and throughput are defined in
  [ADR-012](adr/012-slo-sla-definitions.md). Alert rules for the SLIs that are
  measurable today live in Argus (`rules/slo_alerts.yml`); see
  [runbooks/slo-alerting-rules.md](runbooks/slo-alerting-rules.md). Latency and
  reconnect SLOs are gated on instrumentation that Argus does not yet
  emit (ADR-012, Tier 2).

Argus does not control or coordinate components; it is read-only with respect
to the rest of the system.

---

## Provisioning

### Myrmidons repo (GitOps)
YAML manifests in the Myrmidons repo describe the desired state of the agent
mesh. Proteus dispatches `agamemnon-apply` on merge; Agamemnon reconciles live
state against the manifests via its REST API. The Myrmidons repo is the
authoritative source of container specs and agent templates (not
Mnemosyne).

**Current state:** Myrmidons supports single-host deployments with `local` and
`docker` deployment types. Multi-host agent scheduling via Nomad is deferred to
a future phase and is tracked in
[ADR-009](adr/009-defer-multi-host-nomad-scheduling.md).

### AchaeanFleet
All container images are defined and versioned in AchaeanFleet. Images run on
the `homeric-mesh` Podman network. New agent types require a new Dockerfile
(vessel) in AchaeanFleet before they can be scheduled.

### Proteus
CI/CD pipelines written in Dagger TypeScript. On merge to main in any submodule
repo, Proteus builds the relevant AchaeanFleet images and dispatches
`agamemnon-apply` to apply any updated Myrmidons manifests.

### Canonical Workflow Field Names

Workflow and task schemas across the ecosystem derive their field names from the
**Agamemnon REST API contract**; the Telemachy Pydantic models
(`src/telemachy/models.py`, `TaskSpec`) are the authoritative source. Two layers
exist: the YAML/Pydantic field name authors write, and the JSON key sent to the
Agamemnon REST API (`agamemnon_client.py`). All ecosystem documentation must use
the YAML names below; do not reintroduce the deprecated forms.

| YAML / Pydantic field | Agamemnon wire key | Deprecated — do NOT use |
|-----------------------|--------------------|-------------------------|
| `subject`             | `subject`          | `title`                 |
| `blocked_by`          | `blockedBy`        | `depends_on`            |
| `assign_to`           | `assigneeAgentId`  | —                       |

First-party Odysseus docs are guarded against the deprecated names by
`scripts/check-doc-field-drift.sh` (run via `just check-doc-field-drift`, part
of `just ci`). Submodule repos own their own equivalent guards.

---

## Testing

### Scylla — Ablation Benchmarking
AI agent ablation benchmarking framework. Evaluates agent architectures across
tiered configurations (T0–T6). Scylla reports results back to Agamemnon task
subjects.

### Charybdis — Chaos Testing
Injects faults and adverse conditions into the mesh via Agamemnon's
`/v1/chaos/*` endpoints. Does not bypass Agamemnon to reach components
directly.

---

## Shared Infrastructure

### Mnemosyne
Skills marketplace and team-knowledge memory store backing the `advise` and
`learn` plugins only. Mnemosyne is not an agent-template registry and does not
hold agent specs; those live in the Myrmidons repo.

### Hephaestus
Shared utilities, Claude Code plugins, and the skills registry. Consumed by all
HomericIntelligence repos. Includes changelog tooling, system-info helpers, and
markdown utilities.

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

1. Create the new repo following SGSG + modern-cpp-template conventions.
2. Add it as a submodule under the appropriate category directory in Odysseus:
   `git submodule add <url> <category>/<RepoName>`
3. Update `.gitmodules` and this document's Component Inventory table.
4. Define any new NATS subjects in the schema above.
5. Add a Dockerfile (vessel) to AchaeanFleet if the component runs as a
   container.
6. Add a YAML manifest to the Myrmidons repo for scheduling.
7. Open an ADR if the component introduces a new architectural pattern.
