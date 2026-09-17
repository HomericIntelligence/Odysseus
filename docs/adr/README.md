# Architecture Decision Records (ADRs)

This directory contains all Architecture Decision Records for the
HomericIntelligence ecosystem. Each ADR documents a significant architectural
choice, its context, decision rationale, and consequences.

## Decision Log

| Number | Title | Status | Supersedes | Superseded By |
|--------|-------|--------|------------|---------------|
| [001](001-podman-over-docker.md) | Use Podman as Primary Container Runtime | Accepted | — | — |
| [002](002-nats-event-bridge.md) | Use NATS JetStream as Event Bridge for ai-maestro Webhooks | Accepted | — | — |
| [003](003-nomad-over-k8s.md) | Use Nomad for Multi-Host Container Scheduling Instead of Kubernetes | Accepted | — | — |
| [004](004-extend-not-replace-maestro.md) | Extend ai-maestro via APIs Rather Than Replacing Its Capabilities | Superseded | — | [ADR-006](006-decouple-from-ai-maestro.md) |
| [005](005-nats-subject-schema.md) | NATS Subject Schema | Accepted | Subject examples in ADR 002 | — |
| [006](006-decouple-from-ai-maestro.md) | Decouple HomericIntelligence from ai-maestro | Accepted | — | — |
| [007](007-symlinks-over-submodules.md) | Replace Symlinks with Real Git Submodules | Accepted | — | — |
| [008](008-nats-tls-encryption.md) | Require TLS for All NATS Inter-Service Communication | Proposed | — | — |
| [009](009-nats-authentication.md) | Require Authentication for All NATS Connections | Proposed | — | Decision 3 only, by Proposed [ADR-024](024-one-homeric-nats-application-account.md) if accepted |
| [010](010-nats-mtls-subject-scoped-auth.md) | NATS Mutual-TLS Authentication and Subject-Scoped Authorization | Proposed | — | Decision 3 only, by Proposed [ADR-024](024-one-homeric-nats-application-account.md) if accepted |
| [011](011-extract-python-orchestration-to-agamemnon.md) | Extract Python Orchestration Layer from Keystone to ProjectAgamemnon | Accepted | — | — |
| [012](012-slo-sla-definitions.md) | Define SLO/SLA Targets for the Agent Mesh | Proposed | — | — |
| [013](013-hmas-mesh-wire-contracts.md) | HMAS Mesh Wire Contracts — Role-Addressed Dispatch, State Events, and Task Sizing | Proposed | — | — |
| [014](014-runnable-evidence-for-metric-claims.md) | Runnable Evidence for Metric and Training-Run Claims | Proposed | — | — |
| [015](015-drop-project-prefix.md) | Drop the `Project` Prefix Across the HomericIntelligence Ecosystem | Accepted | — | — |
| [016](016-split-hephaestus.md) | Split `Hephaestus` — Library vs Agentic Plugins | Accepted | — | — |
| [017](017-uv-for-python-pixi-for-toolchains.md) | uv for Pure-Python Repos, pixi Where a Conda Toolchain Is Required | Proposed | — | [Proposed ADR-018](018-uv-ecosystem-wide.md) |
| [018](018-uv-ecosystem-wide.md) | uv Is the Ecosystem-Wide Standard — Toolchains via PyPI, apt, and the Mojo pip Package | Proposed | [Proposed ADR-017](017-uv-for-python-pixi-for-toolchains.md) | — |
| [019](019-lemonade-private-inference-lane.md) | Lemonade as the Private Inference Lane for the Mesh | Proposed | — | — |
| [020](020-mesh-distributed-hephaestus-loop.md) | Distribute the Hephaestus Automation Loop Across the Mesh | Proposed | — | — |
| [021](021-defer-multi-host-nomad-scheduling.md) | Defer Multi-Host Nomad Scheduling to a Future Phase | Proposed | — | — |
| [022](022-layered-provider-neutral-agent-instructions.md) | Layered, Provider-Neutral Agent Instructions | Proposed | — | — |
| [024](024-one-homeric-nats-application-account.md) | One Homeric NATS Application Account with Per-Role Authorization | Proposed | Conflicting Decision 3 portions of Proposed [ADR-009](009-nats-authentication.md) and [ADR-010](010-nats-mtls-subject-scoped-auth.md), only if accepted | — |

ADR-023 is reserved for the Fleet execution and web-interface proposal carried
by [PR #498](https://github.com/HomericIntelligence/Odysseus/pull/498). It is
intentionally absent from this tree until that proposal completes its required
rebase and renumber. A reservation is not an ADR or architectural authority,
so there is no placeholder row or file.

## How to Create a New ADR

1. Copy the [template.md](template.md) to a new file:
   `NNN-kebab-case-title.md`, where `NNN` is the next sequential number.
2. Fill in all sections: Context, Decision, Consequences (Positive, Negative,
   Neutral), and References.
3. Keep **Status** as `Proposed` until a recorded human decision formally
   accepts it. Merge alone does not imply acceptance.
4. If the proposal supersedes another decision, declare that relationship in
   the new ADR and update this decision log's `Superseded By` column. Never
   edit an Accepted ADR body to add a reverse link.
5. Create a pull request with your new ADR.
6. Record formal acceptance through a reviewed status-change PR. After that
   change lands, the Accepted ADR body is frozen.

## ADR Process

- **Proposed:** A new ADR that has not yet been reviewed or accepted.
- **Accepted:** A decision that has been reviewed and approved. Accepted ADRs
  are frozen and never edited.
- **Superseded:** A decision that has been replaced by a later ADR. The
  superseded ADR is kept for historical reference and linked to its
  replacement.

ADRs are **append-only.** Once accepted, an ADR is never edited or deleted. If
a decision needs to change, create a new ADR that references and supersedes the
old one.
