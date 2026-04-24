# Documentation Index

Welcome to the HomericIntelligence documentation hub. This page serves as a table of contents for all architecture, decisions, and operational guides.

---

## Architecture Overview

Start here to understand the HomericIntelligence system as a whole:

- **[System Architecture](architecture.md)** — Complete overview of all components, their roles, and how they interact. Post-ADR-006 architecture with ProjectAgamemnon as the coordination hub.

---

## Architecture Decision Records (ADRs)

All significant architectural decisions are recorded here. ADRs are append-only—once accepted, they are never edited. Superseding decisions get a new ADR that references the old one.

| # | Title | Status | Supersedes |
|---|-------|--------|-----------|
| [001](adr/001-podman-over-docker.md) | Use Podman as Primary Container Runtime | Accepted | — |
| [002](adr/002-nats-event-bridge.md) | Use NATS JetStream as Event Bridge for ai-maestro Webhooks | Accepted | — |
| [003](adr/003-nomad-over-k8s.md) | Use Nomad for Multi-Host Container Scheduling Instead of Kubernetes | Accepted | — |
| [004](adr/004-extend-not-replace-maestro.md) | Extend ai-maestro via APIs Rather Than Replacing Its Capabilities | Superseded by ADR-006 | — |
| [005](adr/005-nats-subject-schema.md) | NATS Subject Schema | Accepted | Subject examples in ADR-002 |
| [006](adr/006-decouple-from-ai-maestro.md) | Decouple HomericIntelligence from ai-maestro | Accepted | — |
| [007](adr/007-symlinks-over-submodules.md) | Replace Symlinks with Real Git Submodules | Proposed | — |

---

## Operational Runbooks

Step-by-step guides for common operational tasks. Execute each runbook top-to-bottom without prior context.

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
- **[Architecture Analysis: Ruflo Integration](odysseus-ruflo-analysis.md)** — Analysis of Ruflo system integration patterns.
- **[E2E Walkthrough Report](e2e-walkthrough-report.md)** — End-to-end system test results and topology validation.

---

## Key Principles

1. **Odysseus is read-mostly.** Most day-to-day changes happen in individual submodule repos, not here.
2. **ADRs are append-only.** Once accepted, never edited. Superseding decisions get a new ADR.
3. **Configs are canonical.** The Nomad and NATS configs in `../configs/` are authoritative.
4. **Submodule pins matter.** Submodule SHAs represent the last known-good cross-repo integration point.
5. **ai-maestro has been fully removed per ADR-006.** ProjectAgamemnon replaces its task coordination role.
