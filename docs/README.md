# Documentation Index

Welcome to the HomericIntelligence documentation hub. This page serves as a table of contents for all architecture, decisions, and operational guides.

---

## Architecture Overview

Start here to understand the HomericIntelligence system as a whole:

- **[System Architecture](architecture.md)** — Complete overview of the 16 canonical repositories (Odysseus plus 15 component gitlinks), their roles, and how current interfaces differ from Proposed ADR target state.

---

## Architecture Decision Records (ADRs)

All significant architectural decisions are recorded here. ADRs are append-only—once accepted, they are never edited. Superseding decisions get a new ADR that references the old one.

This table mirrors the canonical [ADR decision log](adr/README.md). A proposal
describes a possible target; it is not deployed or binding architecture until
its status is formally changed to Accepted. Checked-in runtime schemas,
configuration, and verified live state remain the authority for current
behavior.

| # | Title | Status | Supersedes |
|---|---|---|---|
| [001](adr/001-podman-over-docker.md) | Use Podman as Primary Container Runtime | Accepted | — |
| [002](adr/002-nats-event-bridge.md) | Use NATS JetStream as Event Bridge for ai-maestro Webhooks | Accepted | — |
| [003](adr/003-nomad-over-k8s.md) | Use Nomad for Multi-Host Container Scheduling Instead of Kubernetes | Accepted | — |
| [004](adr/004-extend-not-replace-maestro.md) | Extend ai-maestro via APIs Rather Than Replacing Its Capabilities | Superseded by ADR-006 | — |
| [005](adr/005-nats-subject-schema.md) | NATS Subject Schema | Accepted | Subject examples in ADR-002 |
| [006](adr/006-decouple-from-ai-maestro.md) | Decouple HomericIntelligence from ai-maestro | Accepted | — |
| [007](adr/007-symlinks-over-submodules.md) | Replace Symlinks with Real Git Submodules | Accepted | — |
| [008](adr/008-nats-tls-encryption.md) | Require TLS for All NATS Inter-Service Communication | Proposed | — |
| [009](adr/009-nats-authentication.md) | Require Authentication for All NATS Connections | Proposed | — |
| [010](adr/010-nats-mtls-subject-scoped-auth.md) | NATS Mutual-TLS Authentication and Subject-Scoped Authorization | Proposed | — |
| [011](adr/011-extract-python-orchestration-to-agamemnon.md) | Extract Python Orchestration Layer from Keystone to ProjectAgamemnon | Accepted | — |
| [012](adr/012-slo-sla-definitions.md) | Define SLO/SLA Targets for the Agent Mesh | Proposed | — |
| [013](adr/013-hmas-mesh-wire-contracts.md) | HMAS Mesh Wire Contracts — Role-Addressed Dispatch, State Events, and Task Sizing | Proposed | — |
| [014](adr/014-runnable-evidence-for-metric-claims.md) | Runnable Evidence for Metric and Training-Run Claims | Proposed | — |
| [015](adr/015-drop-project-prefix.md) | Drop the `Project` Prefix Across the HomericIntelligence Ecosystem | Accepted | — |
| [016](adr/016-split-hephaestus.md) | Split `Hephaestus` — Library vs Agentic Plugins | Accepted | — |
| [017](adr/017-uv-for-python-pixi-for-toolchains.md) | uv for Pure-Python Repos, pixi Where a Conda Toolchain Is Required | Proposed | — |
| [018](adr/018-uv-ecosystem-wide.md) | uv Is the Ecosystem-Wide Standard — Toolchains via PyPI, apt, and the Mojo pip Package | Proposed | Proposed ADR-017 |
| [019](adr/019-lemonade-private-inference-lane.md) | Lemonade as the Private Inference Lane for the Mesh | Proposed | — |
| [020](adr/020-mesh-distributed-hephaestus-loop.md) | Distribute the Hephaestus Automation Loop Across the Mesh | Proposed | — |
| [021](adr/021-defer-multi-host-nomad-scheduling.md) | Defer Multi-Host Nomad Scheduling to a Future Phase | Proposed | — |
| [022](adr/022-layered-provider-neutral-agent-instructions.md) | Layered, Provider-Neutral Agent Instructions | Proposed | — |
| [024](adr/024-one-homeric-nats-application-account.md) | One Homeric NATS Application Account with Per-Role Authorization | Proposed | Conflicting Decision 3 portions of Proposed ADR-009 and ADR-010, only if accepted |

ADR-023 is reserved for the Fleet proposal in PR #498 and is intentionally
absent until that proposal completes its required rebase and renumber. The
reservation is not an ADR or architectural authority.

[ADR-022](adr/022-layered-provider-neutral-agent-instructions.md) is the
instruction-modernization governance proposal and remains a dependency for
ecosystem-wide consumer changes. [ADR-024](adr/024-one-homeric-nats-application-account.md)
separately proposes a compatible NATS account topology; neither proposal is
deployed or binding until formally accepted and implemented.

The associated
[modernization disposition ledger](agent-instruction-modernization-ledger.md)
records repository ownership, protected boundaries, dependencies, and evidence
still required without claiming unfinished work as complete.

---

## Operational Runbooks

Contextual guides for common operational tasks. Select the guide that matches
the exact operation, bind its prerequisites and authority, and execute ordered
steps only after its gates are satisfied. Some guides intentionally stop at a
live-state or operator-approval boundary.

| Runbook | When to Use |
|---------|------------|
| [Add a New Host](runbooks/add-new-host.md) | Adding a new machine to the HomericIntelligence mesh |
| [Add a New Agent Type](runbooks/add-new-agent-type.md) | Creating a new agent type and integrating it into the ecosystem |
| [WSL2 Rootless Podman Setup](runbooks/wsl2-podman-setup.md) | Enabling rootless podman on WSL2 for local development |
| [Disaster Recovery](runbooks/disaster-recovery.md) | Recovery procedures for system failure scenarios (e.g., primary Agamemnon host loss) |

---

## NATS Event Bus Reference

- **[NATS Subject Schema](nats-subjects.md)** — Subject patterns, streams, consumers, and lifecycle documentation for the HomericIntelligence event bus. See [ADR 005](adr/005-nats-subject-schema.md) for decision context.

---

## Additional Resources

- **[Architecture Analysis: ai-maestro Migration](odysseus-ai-maestro-analysis.md)** — Historical analysis of the ai-maestro integration and subsequent decoupling.
- **[Historical Architecture Analysis: Ruflo Integration](odysseus-ruflo-analysis.md)** — Preserved 2026-03-27 analysis; not current operating authority.
- **[Historical E2E Walkthrough Report](e2e-walkthrough-report.md)** — Frozen 2026-04-06 evidence; not a current runbook, topology source, or authorization for its retired commands.

---

## AI Agent Boundaries

- **[AGENTS.md](../AGENTS.md)** — AI agent behavior boundaries and context limits (repo root)

---

## Key Principles

1. **Odysseus is read-mostly.** Most day-to-day changes happen in individual submodule repos, not here.
2. **ADRs are append-only.** Once accepted, never edited. Superseding decisions get a new ADR.
3. **Configs are canonical.** The Nomad and NATS configs in `../configs/` are authoritative.
4. **Submodule pins matter.** Submodule SHAs represent the last known-good cross-repo integration point.
5. **ai-maestro is not part of the current meta-repo or runtime coordination path.**
   Agamemnon owns current task coordination; preserved historical references remain evidence,
   not operating authority.
