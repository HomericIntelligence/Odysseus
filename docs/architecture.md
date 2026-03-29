# HomericIntelligence System Architecture

> **Architecture Rewrite In Progress** — ADR-006 supersedes ADR-004. This document reflects
> the pre-migration state. The new architecture replaces ai-maestro with native
> HomericIntelligence components. See [ADR-006](adr/006-decouple-from-ai-maestro.md) for
> the authoritative post-migration architecture.

## Overview

The HomericIntelligence ecosystem is a distributed agent mesh built on top of **ai-maestro**, an existing platform that provides agent lifecycle management, task queuing, messaging, memory, and webhooks via a REST API.

The remaining repositories fill seven genuine gaps that ai-maestro does not cover. Every new repo integrates with ai-maestro exclusively via its documented REST API (`/agents`, `/tasks`, `/messages`, `/memory`, `/docker`, `/host-sync`) and webhook callbacks. No new repo duplicates ai-maestro capabilities.

---

## ai-maestro (Do Not Modify)

**Repo:** `infrastructure/ai-maestro`
**Role:** Core platform and single source of truth for the agent mesh.

ai-maestro provides:
- Agent registry and lifecycle (`/agents` — create, start, stop, delete)
- Task queue and dispatch (`/tasks`)
- Agent-to-agent messaging via AMP protocol (`/messages`)
- Persistent memory/knowledge store (`/memory`)
- Container creation via Docker socket (`/docker/create`)
- Multi-host peer sync (`/host-sync`)
- Outbound webhooks on agent events

ai-maestro is treated as a black box. All other repos are consumers of its API. The submodule at `infrastructure/ai-maestro` is pinned to a known-good SHA and must never be modified in this repo.

---

## The 7 Genuine Gaps and How They Are Filled

| # | Gap | Filled By | Integration Method |
|---|---|---|---|
| 1 | No standardized container image library for agent types | AchaeanFleet | Pushes images; ai-maestro `/docker/create` pulls them |
| 2 | No pub/sub fan-out or event replay for webhooks | ProjectHermes | Receives ai-maestro webhooks, publishes to NATS JetStream |
| 3 | No multi-host container scheduling | Myrmidons + Nomad | Reads ai-maestro state; submits Nomad jobs; reconciles via `/agents` |
| 4 | No observability / metrics pipeline | ProjectArgus | Scrapes ai-maestro `/metrics` (if exposed) + Nomad + NATS; Grafana UI |
| 5 | No declarative desired-state management | Myrmidons | Applies YAML manifests to ai-maestro via REST; git-ops reconciler |
| 6 | No workflow / orchestration layer | ProjectTelemachy | Chains ai-maestro tasks into named multi-step workflows |
| 7 | No agent template / marketplace registry | ProjectMnemosyne | Stores agent templates; AchaeanFleet + Myrmidons consume at build/apply time |

Additional repos cover supporting concerns:

| Repo | Concern |
|---|---|
| ProjectKeystone | Automated task DAG execution; watches NATS task events, advances dependency graphs via ai-maestro REST API |
| ProjectProteus | CI/CD pipelines; builds AchaeanFleet images, runs Myrmidons apply on merge |
| ProjectOdyssey | Research sandbox; experimental agents not yet promoted to production |
| ProjectScylla | AI agent ablation benchmarking; evaluates agent architectures across tiered configurations (T0–T6) |
| ProjectHephaestus | Shared utilities (changelog, system-info, markdown tools); not yet imported as a dependency by other repos |

---

## Integration Diagram

```
                        ┌─────────────────────────────────────────────┐
                        │               ai-maestro                    │
                        │  /agents  /tasks  /messages  /memory        │
                        │  /docker/create  /host-sync  webhooks →     │
                        └────────────┬──────────────┬─────────────────┘
                                     │ REST API      │ webhooks (HTTP POST)
              ┌──────────────────────┼──────────────▼──────────────────────────┐
              │                      │         ProjectHermes                   │
              │                      │  webhook receiver → NATS JetStream      │
              │                      │  subjects: hi.agents.{host}.{name}.{verb}│
              │                      │           hi.tasks.{team}.{task}.{verb} │
              │                      └────────────┬────────────────────────────┘
              │                                   │ NATS pub/sub
              │            ┌──────────────────────┼──────────────────────┐
              │            │                      │                      │
              ▼            ▼                      ▼                      ▼
        Myrmidons     ProjectArgus          ProjectTelemachy        ProjectScylla
        (apply YAML   (metrics/alerts       (workflow engine        (ablation
         to /agents)   Grafana dashboards)   chains /tasks)          benchmarking)
              │
              ▼
           Nomad cluster  ◄── configs/nomad/client.hcl + server.hcl
              │
              ▼
        AchaeanFleet
        (container image
         library in registry)
              ▲
              │ build + push
        ProjectProteus
        (CI/CD pipelines)
              │
              ▼
        ProjectKeystone
        (DAG advancement
         via REST + NATS)

  ProjectMnemosyne ──────► AchaeanFleet (image templates)
  (agent marketplace)  └──► Myrmidons (YAML manifest templates)

  ProjectHephaestus ─────► available for future shared code (e.g., maestro-client)
  ProjectOdyssey    ─────► research sandbox (promotes → AchaeanFleet)
```

---

## Component Table

| Repo | Category | Gap Filled | ai-maestro Integration | Notes |
|---|---|---|---|---|
| ai-maestro | infrastructure | n/a (core platform) | — | Do not modify |
| AchaeanFleet | infrastructure | Standardized agent image library | `/docker/create` pulls images | Vessels = Dockerfiles per agent type |
| ProjectHermes | infrastructure | Webhook fan-out and event replay | Receives outbound webhooks | Publishes to NATS JetStream |
| ProjectArgus | infrastructure | Observability and alerting | Scrapes metrics endpoints | Grafana + Prometheus stack |
| Myrmidons | provisioning | Declarative desired-state (GitOps) | REST CRUD on `/agents`, `/tasks` | `just apply` reconciles YAML → live state |
| ProjectTelemachy | provisioning | Multi-step workflow orchestration | Chains `/tasks` calls | Workflow definitions as YAML |
| ProjectKeystone | provisioning | Automated task DAG execution | Watches NATS task events; advances via REST `/tasks` | JetStream durable consumer |
| ProjectProteus | ci-cd | Automated build and deploy pipelines | Triggers Myrmidons apply on merge | Builds AchaeanFleet images |
| ProjectMnemosyne | shared | Agent template marketplace / registry | Consumed by AchaeanFleet + Myrmidons | `marketplace.json` catalog |
| ProjectHephaestus | shared | Shared utilities and tooling | n/a (library only) | Not yet imported by other repos |
| ProjectOdyssey | research | Experimental agent research sandbox | Full REST API access | Promotes to AchaeanFleet when stable |
| ProjectScylla | research | AI agent ablation benchmarking | Standalone evaluation framework | Measures agent performance across T0–T6 tiers |
