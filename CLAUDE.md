# CLAUDE.md — Odysseus

## Project Overview

Odysseus is the meta-repo and unified architecture hub for the HomericIntelligence distributed agent mesh. It is the top-level entry point for the entire ecosystem: it holds Architecture Decision Records, operational runbooks, shared infrastructure configs, and references every other HomericIntelligence repository as a git submodule.

Odysseus itself contains no application code. Its value is coordination: it ensures that any engineer (or AI agent) starting here can understand the full system, find every component, and perform cross-cutting operations with a single `just` command.

## Key Principles

1. **Odysseus is read-mostly.** Most day-to-day changes happen in the individual submodule repos, not here.
2. **ai-maestro has been removed per ADR-006.** ProjectAgamemnon (control/ProjectAgamemnon) replaces ai-maestro's task coordination role.
3. **ADRs are append-only.** Once an ADR is accepted it is never edited. Superseding decisions get a new ADR that references the old one.
4. **Configs here are canonical.** The Nomad and NATS configs in `configs/` are the authoritative source. Individual hosts copy or symlink from here.
5. **Submodule pins matter.** The submodule SHAs in this repo represent the last known-good cross-repo integration point.

## Repository Structure

```
Odysseus/
├── docs/
│   ├── architecture.md           # System-wide architecture overview and component map
│   ├── adr/
│   │   ├── 001-podman-over-docker.md
│   │   ├── 002-nats-event-bridge.md
│   │   ├── 003-nomad-over-k8s.md
│   │   ├── 004-extend-not-replace-maestro.md
│   │   ├── 005-nats-subject-schema.md
│   │   └── 006-decouple-from-ai-maestro.md
│   └── runbooks/
│       ├── add-new-host.md
│       ├── add-new-agent-type.md
│       └── disaster-recovery.md
├── configs/
│   ├── nomad/
│   │   ├── client.hcl
│   │   └── server.hcl
│   └── nats/
│       ├── server.conf
│       └── leaf.conf
├── infrastructure/               # git submodules
│   ├── AchaeanFleet
│   ├── ProjectArgus
│   └── ProjectHermes
├── control/                      # git submodules
│   ├── ProjectAgamemnon          # Planning + HMAS orchestration (replaces ai-maestro)
│   └── ProjectNestor             # Research, ideation, handoff to Agamemnon
├── provisioning/                 # git submodules
│   ├── ProjectTelemachy
│   ├── ProjectKeystone
│   └── Myrmidons
├── ci-cd/                        # git submodules
│   └── ProjectProteus
├── research/                     # git submodules
│   ├── ProjectOdyssey
│   └── ProjectScylla
├── testing/                      # git submodules
│   └── ProjectCharybdis          # Chaos/resilience testing via Agamemnon /v1/chaos/*
├── shared/                       # git submodules
│   ├── ProjectMnemosyne
│   └── ProjectHephaestus
├── .gitmodules
├── justfile
└── pixi.toml
```

## Development Guidelines

- Use `pixi run` or `just` for all task execution. Never run scripts directly.
- When adding a new submodule: `git submodule add <url> <path>`, update `.gitmodules`, and document the repo in `docs/architecture.md`.
- When writing a new ADR: copy the format from an existing ADR, use the next sequential number, and set Status to "Proposed" until merged.
- Runbooks should be written as numbered steps that can be executed top-to-bottom without prior context.
- **ai-maestro has been fully removed per ADR-006.** ProjectAgamemnon replaces its task coordination role.

## Common Commands

```bash
# Initialize all submodules after a fresh clone
just bootstrap

# Check status of all submodules
just status

# Apply Myrmidons declarative YAML manifests via Agamemnon API
just apply-all

# Start the NATS event bridge (ProjectHermes)
just hermes-start

# Start the observability stack (ProjectArgus)
just argus-start

# Run a named workflow via ProjectTelemachy
just telemachy-run WORKFLOW=my-workflow

# Pull latest commits for all submodules
just update-submodules
```
