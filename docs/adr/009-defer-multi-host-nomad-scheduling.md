# ADR 009: Defer Multi-Host Nomad Scheduling to a Future Phase

**Status:** Proposed

---

## Context

ADR-003 accepted Nomad as the container scheduler for HomericIntelligence,
chosen over Kubernetes for its single-binary simplicity and right-sized
operational footprint. The canonical Nomad configs live in `configs/nomad/`
(`server.hcl`, `client.hcl`) and the deployment runbook
(`docs/deployment.md`, Step 5) describes a single-node bootstrap.

However, the agent mesh does not yet schedule agents across multiple hosts
through Nomad. Today, Myrmidons supports only `local` and `docker` deployment
types, and the Myrmidons worker pool is a single-host, pull-based pool. The
architecture document (`docs/architecture.md`) describes multi-host scheduling
as "planned for a future phase."

A "planned" state with no durable tracker can go stale indefinitely. The prior
attempts to track this work were GitHub issues that have since been closed
(HomericIntelligence/Myrmidons#5 — "Document Nomad integration strategy", and
Odysseus#115), so they no longer serve as a live record. This ADR provides a
durable, append-only tracker for the deferral itself.

## Decision

We **defer multi-host Nomad scheduling to a future phase** and record that
deferral here as the canonical tracker.

Key points:

- **Current supported state:** Myrmidons supports single-host deployments with
  the `local` and `docker` deployment types only. The worker pool is a
  single-host, pull-based pool (`MaxAckPending=1`).
- **What is deferred:** Multi-host agent scheduling and clustering via Nomad —
  i.e., Myrmidons submitting Nomad job specs that place agent containers across
  the Tailscale-connected host fleet, as envisioned in ADR-003.
- **Why defer:** The current single-host model meets present needs. Multi-host
  scheduling requires a multi-node Nomad cluster (beyond the
  `bootstrap_expect=1` single-server config currently checked in), a
  Myrmidons-to-Nomad job submission path, and host-fleet placement logic. That
  work is not yet scheduled.
- **How it is tracked:** This ADR is the canonical record. All "planned for a
  future phase" references in `docs/architecture.md` link here. Because ADRs
  are append-only and never auto-closed, this reference cannot go stale the
  way a closed GitHub issue does. When the work begins, a new ADR documenting
  the multi-host rollout will reference and supersede this one.

## Consequences

**Positive:**
- The "planned" state in the architecture doc now has a durable, canonical
  tracker that cannot be silently closed.
- The current single-host capability and the deferred multi-host capability
  are clearly distinguished for onboarding engineers and AI agents.
- Future multi-host work has a documented starting point and supersession path.

**Negative:**
- An ADR is a coarser tracker than a project board; granular task breakdown
  for the eventual multi-host rollout will still need issues when the work is
  scheduled. Mitigation: those issues link back to this ADR.

**Neutral:**
- No code or configuration changes. `configs/nomad/` remains the canonical
  single-node bootstrap config; ADR-003 remains the accepted scheduler choice.

## References

- [ADR 003](003-nomad-over-k8s.md) - Use Nomad for Multi-Host Container
  Scheduling Instead of Kubernetes (the scheduler choice this ADR defers the
  rollout of)
- [Issue #209](https://github.com/HomericIntelligence/Odysseus/issues/209) -
  Nomad multi-host described as 'planned' with no tracking issue
