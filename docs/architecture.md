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
a git submodule. Odysseus itself contains no application code.

---

## Component Inventory

| Component | Category | Role |
|-----------|----------|------|
| **Odysseus** | meta | User interface, observability hub, and meta-repo. Bidirectional with user. Consumes Argus dashboards. |
| **Agamemnon** | control | Planning, coordination, and HMAS orchestration (L0–L3). GitHub Issues/Projects is the backing store. Does not perform research or expose a user UI. |
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
| **Hephaestus** | shared | Shared utilities, Claude Code plugins, and skills registry. Used across all repos. |
| **Odyssey** | research | Standalone Mojo ML training framework. Reproduces classic AI/ML research papers; provides reusable tensor ops, autograd, and training infrastructure. Not integrated with the agent mesh; implementations live entirely in-repo as Mojo libraries and executables. |
| ~~ai-maestro~~ | removed | Removed per [ADR-006](adr/006-decouple-from-ai-maestro.md). No submodule entry and no `infrastructure/ai-maestro/` directory. Do not reintroduce. |

---

## Network Topology

All inter-host traffic flows over **Tailscale** — a WireGuard mesh VPN. The
mesh name is `tail8906b5.ts.net`. No inter-host port is exposed to the public
internet; every service assumes Tailscale reachability for cross-node
communication.

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
  │   HMAS L0–L3 · GitHub Issues/Projects backing store                │
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
each hop is bidirectional. All communication flows **through** Keystone
(invisible transport); no component holds a direct socket reference to
another. Keystone is a transport detail, not a pipeline stage. All workers
run AchaeanFleet container images and integrate advise-before / learn-after
around every task.

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
