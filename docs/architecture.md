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

---

## Component Inventory

| Component | Category | Role |
|-----------|----------|------|
| **Odysseus** | meta | User interface, observability hub, and meta-repo. Bidirectional with user. Consumes Argus dashboards. |
| **Agamemnon** | control | Planning, coordination, and HMAS orchestration (L0–L3). Its default store is in-memory; GitHub Issues write-through is optional. GitHub Projects is not its backing store. Agamemnon does not perform research or expose a user UI. |
| **Nestor** | control | C++20 research-request intake and status service. It accepts ideas (`POST /v1/research`), stores pending items, and publishes a completion event after an explicit completion request. Research-pool dispatch, interviewing, and ideation are Proposed ADR-013 targets, not behavior supplied by the pinned service. |
| **Keystone** | transport | C++ transport library with an in-process lock-free MessageBus and an optional NATS JetStream bridge. Callers that adopt Keystone resolve its backend through configuration; REST services and direct NATS clients do not pass through it. |
| **Hermes** | infrastructure | Inbound webhook-to-NATS bridge. The pinned service validates signed HTTP webhooks and publishes supported events to NATS; it has no outbound-delivery or email implementation. |
| **Argus** | infrastructure | Observability: Prometheus metrics, Loki log aggregation, Grafana dashboards, Promtail scraping. Feeds Odysseus dashboards. |
| **AchaeanFleet** | infrastructure | OCI base and vessel images for AI-agent runtimes. It does not own every HomericIntelligence service image. Its primary mesh Compose file uses `agamemnon-frontend` and `agent-backend`; the worker Compose file uses `homeric-mesh`. |
| **Myrmidons repo** | provisioning | Versioned desired-state dataset with agent templates and container specs. Its pinned schema enumerates `local`, `docker`, and a future-reserved `nomad` discriminator; current runtime scheduling implements `local` and `docker`. A separately approved, compatible Agamemnon reconciler would apply selected state. The pinned dataset is not proof of live state and has no `apply` recipe. Multi-host scheduling via Nomad remains target work (see [Proposed ADR-021](adr/021-defer-multi-host-nomad-scheduling.md)). |
| **Telemachy** | provisioning | Declarative workflow engine + work description and epic registration. Proposed ADR-013 assigns it workflow-to-epic registration and `hi.pipeline.epic.*.registered` publication ([proposal](adr/013-hmas-mesh-wire-contracts.md)); verify current consumers and deployment before treating that target as live. |
| **Proteus** | ci-cd | CI/CD. Dagger TypeScript pipelines build AchaeanFleet images. The pinned revision accepts AchaeanFleet `image-pushed` events and sends `agamemnon-apply` to Myrmidons, but the pinned Myrmidons revision has no receiver or `apply` recipe, so that dispatch does not currently reconcile desired state. |
| **Myrmidons (workers)** | workers | Proposed ADR-013 targets a pull-based worker pool on role-addressed queues `hi.myrmidon.{domain}.{role}.task.>` with domain-crossed HMAS roles ([proposal](adr/013-hmas-mesh-wire-contracts.md)). Verify reconciler and worker state before treating that pool as deployed. Multi-host clustering via Nomad is also only proposed for a future phase (see [Proposed ADR-021](adr/021-defer-multi-host-nomad-scheduling.md)). |
| **Scylla** | testing | AI agent ablation benchmarking; evaluates agent architectures across tiered configurations (T0–T6). |
| **Charybdis** | testing | Chaos and resilience testing. Injects faults via Agamemnon `/v1/chaos/*` endpoints. |
| **Athena** | agentic | Public `athena@Athena` coding-harness plugin. The pinned gitlink exposes 14 root skill routers; the planned Athena release preserves 17 skill IDs and is not integrated until that release is reviewed and pinned. Athena depends on Mnemosyne for knowledge and Hephaestus for automation support. |
| **Mnemosyne** | shared | Knowledge store and retrieval backend used by Athena's `advise` and `learn` skills. It is neither a plugin marketplace nor an agent-template registry. |
| **Hephaestus** | shared | Shared runtime utilities and optional automation product layer. It supports Athena but is not installed as a second coding-harness skill plugin. |
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

---

## System Diagram

The diagram includes target-state edges from Proposed ADRs 013 and 020. It is a
coordination view, not a live-deployment readback.

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
  │  C++20 research intake     │    │  Prometheus · Loki · Grafana     │
  │  and request status        │    │  Promtail                        │
  └────────────────┬───────────┘    └──────────────────────────────────┘
                   │ handoff
                   ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                      Agamemnon                               │
  │   HMAS L0–L3 · in-memory store · optional Issues write-through     │
  │   /v1/tasks  /v1/agents  /v1/chaos/*  /v1/workflows                │
  └─────────────────┬──────────────────────────────────────────────────┘
                    │ proposed role-addressed dispatch over NATS
                    ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                    NATS JetStream                              │
  │   Direct clients · optional Keystone NATS bridge                    │
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
  │   AI-agent base/vessel images · homeric-mesh Podman network     │
  └──────────────────────────────────────────────────────────────────┘
           ▲ builds & pushes
  ┌──────────────────────────────────────────────────────────────────┐
  │                       Proteus                             │
  │   Dagger TypeScript · AchaeanFleet image-pushed relay            │
  └──────────────────────────────────────────────────────────────────┘

  External services ──► Hermes ──► NATS (supported webhook subjects) ──► consumers

  Myrmidons repo (GitOps YAML manifests) ──► Agamemnon API reconciliation
  Telemachy  ──► Agamemnon REST API; a Nestor handoff is only Proposed ADR-013
  Charybdis  ──► Agamemnon /v1/chaos/* (fault injection)
  Scylla     ──► ablation benchmarking (T0–T6 tiers)
  Athena     ──► public athena@Athena plugin; pinned revision has 14 routers
  Mnemosyne  ──► knowledge store/backend for Athena advise and learn
  Hephaestus ──► shared runtime utilities and automation support
  Odyssey    ──► standalone Mojo ML framework (paper reproductions, in-repo only)
```

---

## Proposed Pipeline Flow

The following end-to-end target is proposed by
[ADR-013](adr/013-hmas-mesh-wire-contracts.md) and
[ADR-020](adr/020-mesh-distributed-hephaestus-loop.md). It must not be used as
evidence that every stage is deployed:

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
 8. Each stage selects only the skills justified by its task; the item moves
    through implementation, PR review (state:implementation-go), and the
    dedicated merger stage
       │  child completion wakes blocked parents in Agamemnon
       ▼
 9. delegate_unblocked_children dispatches the next burst until the
    epic's tree reaches Completed
```

In the proposed flow, interviews, escalations, and dashboards use the named
subjects shown above. Current control integrations also make explicit REST
calls to Agamemnon, including Telemachy workflow submission and Charybdis fault
injection. Keystone is a transport detail rather than a pipeline stage; it is
not the route for every current interaction. The target worker flow uses
AchaeanFleet images. Knowledge retrieval and preservation are contextual skill
choices, not mandatory wrappers around every task.

---

## Proposed Mesh State Mapping

Proposed ADR-013 defines the following one-to-one mapping. Each service's
checked-in implementation remains the current behavioral authority:

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

## NATS Subject Schema

All first-party subjects use the `hi.` prefix. The current routing summary and
component-authority links live in [`docs/nats-subjects.md`](nats-subjects.md).
Agamemnon's pinned OpenAPI and Hermes's pinned models/publisher own their
implemented subjects; the versioned dispatch schema owns `hi/v1` pipeline
packets. Proposed ADR-013 records candidate role-addressed and pipeline
subjects, not current publisher or consumer evidence.

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
[Proposed ADR-021](adr/021-defer-multi-host-nomad-scheduling.md).

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

## Agent and Shared Infrastructure

### Athena
Athena owns the public `athena@Athena` coding-harness plugin. The integrated
gitlink exposes 14 root skill routers. The planned Athena release preserves 17
skill IDs, but that target is not deployed until the release is reviewed and
the gitlink is updated. Each skill is selected for a discriminating task and
may load detailed references or scripts contextually. Athena uses Mnemosyne as
its knowledge backend and Hephaestus for shared automation support; neither
dependency is installed as a duplicate skill plugin.

### Mnemosyne
Team-knowledge store and retrieval backend for Athena's `advise` and `learn`
skills. Mnemosyne is not a plugin marketplace or agent-template registry and
does not hold agent specs; those live in the Myrmidons repo.

### Hephaestus
Shared runtime utilities and an optional automation product layer consumed
across HomericIntelligence. It includes prompt and orchestration support,
changelog tooling, system-info helpers, and Markdown utilities. The public
coding-harness skills live in Athena, not Hephaestus.

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
