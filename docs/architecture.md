# HomericIntelligence System Architecture

> **Post-migration architecture.** This document reflects the state after ADR-006 was implemented.
> ai-maestro has been replaced by native HomericIntelligence components. The
> `infrastructure/ai-maestro` submodule remains pinned for backward compatibility but carries no
> active role and will be removed. See [ADR-006](adr/006-decouple-from-ai-maestro.md).

---

## Overview

HomericIntelligence is a distributed agent mesh built from purpose-built, loosely-coupled
components. There is no central platform dependency: coordination is owned by ProjectAgamemnon,
transport is owned by ProjectKeystone (BlazingMQ + NATS JetStream), and every other component
integrates through well-defined subjects rather than direct service calls.

Odysseus is the meta-repo and user-facing hub. It holds Architecture Decision Records, runbooks,
canonical configs, and references every other repository as a git submodule. Odysseus itself
contains no application code.

---

## Component Inventory

| Component | Category | Role |
|-----------|----------|------|
| **Odysseus** | meta | User interface, observability hub, and meta-repo. Bidirectional with user. Consumes Argus dashboards. |
| **ProjectAgamemnon** | control | Planning, coordination, and HMAS orchestration (L0–L3). GitHub Issues/Projects is the backing store. Does not perform research or expose a user UI. |
| **ProjectNestor** | control | Research, ideation, and search. Idea → research → review brief → handoff to Agamemnon. Uses Telemachy internally for multi-step workflows. |
| **ProjectKeystone** | transport | Invisible transport layer. BlazingMQ for intra-host (<500 ns, >2 M msg/sec); NATS JetStream (nats.c v3.12.0) for cross-host over Tailscale. Components talk *through* Keystone, never *to* it. |
| **ProjectHermes** | infrastructure | External message delivery bridge. Routes external-service events into NATS and delivers outbound messages to external services. |
| **ProjectArgus** | infrastructure | Observability: Prometheus metrics, Loki log aggregation, Grafana dashboards, Promtail scraping. Feeds Odysseus dashboards. |
| **AchaeanFleet** | infrastructure | Container image library. All agent and service images. Built by Proteus; run on the `homeric-mesh` Podman network. |
| **Myrmidons repo** | provisioning | GitOps source of truth. YAML manifests describe desired agent state; Agamemnon API reconciliation applies them. Also holds all agent templates and container specs. Multi-host scheduling via Nomad is planned for a future phase; currently supports `local` and `docker` deployment types only. |
| **ProjectTelemachy** | provisioning | Declarative workflow engine. Used programmatically by Agamemnon and Nestor. Not a user-facing service. |
| **ProjectProteus** | ci-cd | CI/CD. Dagger TypeScript pipelines. Builds AchaeanFleet images; dispatches `agamemnon-apply` on merge. |
| **Myrmidons (workers)** | workers | Single-host worker pool. Pull-based, rate-limited (MaxAckPending=1). Queue subscription determines role. Multi-host clustering via Nomad is planned for a future phase. |
| **ProjectScylla** | testing | AI agent ablation benchmarking; evaluates agent architectures across tiered configurations (T0–T6). |
| **ProjectCharybdis** | testing | Chaos and resilience testing. Injects faults via Agamemnon `/v1/chaos/*` endpoints. |
| **ProjectMnemosyne** | shared | Memory store for `advise` and `learn` plugins only. Not a template registry. |
| **ProjectHephaestus** | shared | Shared utilities, Claude Code plugins, and skills registry. Used across all repos. |
| **ProjectOdyssey** | research | Mojo ML research sandbox. Stable work graduates to AchaeanFleet. |
| ~~ai-maestro~~ | deprecated | Removed per ADR-006. Submodule pinned at `infrastructure/ai-maestro` for backward compatibility only. Do not add new dependencies. |

---

## Network Topology

All inter-host traffic flows over **Tailscale** — a WireGuard mesh VPN. The mesh name is
`tail8906b5.ts.net`. No inter-host port is exposed to the public internet; every service assumes
Tailscale reachability for cross-node communication.

Intra-host communication uses BlazingMQ (via ProjectKeystone) and does not traverse the network.

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
  │       ProjectNestor        │    │          ProjectArgus            │
  │  research · ideation       │    │  Prometheus · Loki · Grafana     │
  │  Telemachy workflows       │    │  Promtail                        │
  └────────────────┬───────────┘    └──────────────────────────────────┘
                   │ handoff
                   ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                      ProjectAgamemnon                               │
  │   HMAS L0–L3 · GitHub Issues/Projects backing store                │
  │   /v1/tasks  /v1/agents  /v1/chaos/*  /v1/workflows                │
  └─────────────────┬──────────────────────────────────────────────────┘
                    │ dispatch (via Keystone NATS subjects)
                    ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     ProjectKeystone                                 │
  │   BlazingMQ (intra-host) · NATS JetStream (cross-host/Tailscale)   │
  └──────┬──────────────────────┬──────────────────────────────────────┘
         │ hi.myrmidon.{type}.> │ hi.research.>
         ▼                      ▼
  ┌─────────────────┐   ┌───────────────────┐
  │  Myrmidons      │   │  Research workers  │
  │  (worker pool)  │   │  (pull, rate-lim.) │
  │  MaxAckPending=1│   │  MaxAckPending=1   │
  └────────┬────────┘   └───────────────────┘
           │ runs images from
           ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                        AchaeanFleet                              │
  │   container image library · homeric-mesh Podman network         │
  └──────────────────────────────────────────────────────────────────┘
           ▲ builds & pushes
  ┌──────────────────────────────────────────────────────────────────┐
  │                       ProjectProteus                             │
  │   Dagger TypeScript · builds images · dispatches agamemnon-apply │
  └──────────────────────────────────────────────────────────────────┘

  External services ──► ProjectHermes ──► NATS (hi.pipeline.>) ──► internal consumers

  Myrmidons repo (GitOps YAML manifests) ──► Agamemnon API reconciliation
  ProjectTelemachy  ◄── used by Agamemnon + Nestor programmatically
  ProjectCharybdis  ──► Agamemnon /v1/chaos/* (fault injection)
  ProjectScylla     ──► ablation benchmarking (T0–T6 tiers)
  ProjectMnemosyne  ──► advise/learn plugins only
  ProjectHephaestus ──► shared utilities, skills registry (all repos)
  ProjectOdyssey    ──► research sandbox ──► graduates to AchaeanFleet
```

---

## Pipeline Flow

```
User ↔ Odysseus ↔ Nestor ↔ Agamemnon ↔ Myrmidons workers
```

Each hop is bidirectional. All communication flows **through** Keystone (invisible transport); no
component holds a direct socket reference to another. Keystone is a transport detail, not a
pipeline stage.

---

## Transport Layer (ProjectKeystone)

ProjectKeystone provides two transport backends, selected by deployment scope:

| Backend | Scope | Latency | Throughput | Protocol |
|---------|-------|---------|------------|----------|
| BlazingMQ | Intra-host | <500 ns | >2 M msg/sec | In-process / shared memory |
| NATS JetStream | Cross-host | Network-bound | High | nats.c v3.12.0 over Tailscale |

Components publish and subscribe to named subjects. They never hold a reference to Keystone
itself; the transport is resolved at startup via configuration.

---

## NATS Subject Schema

All subjects use the `hi.` namespace prefix.

| Subject pattern | Publishers | Subscribers | Notes |
|-----------------|-----------|-------------|-------|
| `hi.research.>` | Agamemnon, Nestor | Research myrmidons (pull) | JetStream pull consumer |
| `hi.myrmidon.{type}.>` | Agamemnon | Pipeline myrmidons (pull) | JetStream pull consumer; `{type}` maps to queue group |
| `hi.pipeline.>` | Odysseus, Argus, Hermes | Multiple (pub/sub) | Fan-out; Hermes bridges external events here |
| `hi.agents.>` | Agamemnon, Hermes | Argus (pub/sub) | Agent lifecycle events |
| `hi.tasks.>` | Agamemnon | Odysseus, Argus (pub/sub) | Task state changes |
| `hi.logs.>` | All components | Argus/Loki, Odysseus (pub) | Structured log forwarding |

---

## Observability (ProjectArgus)

ProjectArgus provides the full observability stack:

- **Prometheus** — scrapes metrics from Agamemnon, Nestor, Keystone, Hermes, and Myrmidon workers.
- **Loki + Promtail** — aggregates structured logs from all components via `hi.logs.>`.
- **Grafana** — dashboards surfaced to Odysseus for user-facing visibility.

Argus does not control or coordinate components; it is read-only with respect to the rest of the
system.

---

## Provisioning

### Myrmidons repo (GitOps)
YAML manifests in the Myrmidons repo describe the desired state of the agent mesh. Proteus
dispatches `agamemnon-apply` on merge; Agamemnon reconciles live state against the manifests via
its REST API. The Myrmidons repo is the authoritative source of container specs and agent
templates (not ProjectMnemosyne).

**Current state:** Myrmidons supports single-host deployments with `local` and `docker` deployment
types. Multi-host agent scheduling via Nomad is planned for a future phase and is tracked in
HomericIntelligence/Myrmidons#5.

### AchaeanFleet
All container images are defined and versioned in AchaeanFleet. Images run on the `homeric-mesh`
Podman network. New agent types require a new Dockerfile (vessel) in AchaeanFleet before they can
be scheduled.

### ProjectProteus
CI/CD pipelines written in Dagger TypeScript. On merge to main in any submodule repo, Proteus
builds the relevant AchaeanFleet images and dispatches `agamemnon-apply` to apply any updated
Myrmidons manifests.

---

## Testing

### ProjectScylla — Ablation Benchmarking
AI agent ablation benchmarking framework. Evaluates agent architectures across tiered
configurations (T0–T6). Scylla reports results back to Agamemnon task subjects.

### ProjectCharybdis — Chaos Testing
Injects faults and adverse conditions into the mesh via Agamemnon's `/v1/chaos/*` endpoints.
Does not bypass Agamemnon to reach components directly.

---

## Shared Infrastructure

### ProjectMnemosyne
Memory store for the `advise` and `learn` plugins only. Mnemosyne is not a template registry and
does not hold agent specs; those live in the Myrmidons repo.

### ProjectHephaestus
Shared utilities, Claude Code plugins, and the skills registry. Consumed by all HomericIntelligence
repos. Includes changelog tooling, system-info helpers, and markdown utilities.

### ProjectOdyssey
Mojo ML research sandbox. Experimental work that is not production-ready lives here. When an
experiment reaches stability it is promoted to AchaeanFleet as a new vessel.

---

## Adding a New Component

1. Create the new repo following SGSG + modern-cpp-template conventions.
2. Add it as a submodule under the appropriate category directory in Odysseus:
   `git submodule add <url> <category>/<RepoName>`
3. Update `.gitmodules` and this document's Component Inventory table.
4. Define any new NATS subjects in the schema above.
5. Add a Dockerfile (vessel) to AchaeanFleet if the component runs as a container.
6. Add a YAML manifest to the Myrmidons repo for scheduling.
7. Open an ADR if the component introduces a new architectural pattern.
