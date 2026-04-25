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
| [007](007-symlinks-over-submodules.md) | Replace Symlinks with Real Git Submodules | Proposed | — | — |

## How to Create a New ADR

1. Copy the [template.md](template.md) to a new file:
   `NNN-kebab-case-title.md`, where `NNN` is the next sequential number.
2. Fill in all sections: Context, Decision, Consequences (Positive, Negative,
   Neutral), and References.
3. Set **Status** to `Proposed` until the ADR is merged and accepted.
4. If your ADR supersedes or is superseded by another, link them both ways
   (e.g., `Supersedes: [ADR-004](004-...)` and update that ADR with
   `Superseded By: [ADR-006](...)`).
5. Create a pull request with your new ADR.
6. Once merged, you may update the Status field if the decision is formally
   accepted by the team.

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
