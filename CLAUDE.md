# CLAUDE.md — Odysseus

## Project Overview

Odysseus is the meta-repo and unified architecture hub for the HomericIntelligence distributed agent mesh. It is the top-level entry point for the entire ecosystem: it holds Architecture Decision Records, operational runbooks, shared infrastructure configs, and references every other HomericIntelligence repository as a git submodule.

Odysseus itself contains no application code. Its value is coordination: it ensures that any engineer (or AI agent) starting here can understand the full system, find every component, and perform cross-cutting operations with a single `just` command.

> **AI agents:** Before operating in this repo, read [AGENTS.md](AGENTS.md) for
> behavior boundaries, permitted tools, off-limits files, and escalation paths.

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
│   ├── deployment.md             # Deployment runbook for a fresh control host
│   ├── onboarding.md             # Contributor onboarding + recipe cheatsheet
│   ├── adr/
│   │   ├── README.md
│   │   ├── template.md
│   │   ├── 001-podman-over-docker.md
│   │   ├── 002-nats-event-bridge.md
│   │   ├── 003-nomad-over-k8s.md
│   │   ├── 004-extend-not-replace-maestro.md
│   │   ├── 005-nats-subject-schema.md
│   │   ├── 006-decouple-from-ai-maestro.md
│   │   ├── 007-symlinks-over-submodules.md
│   │   ├── 008-nats-tls-encryption.md
│   │   ├── 009-defer-multi-host-nomad-scheduling.md
│   │   ├── 009-nats-authentication.md
│   │   ├── 010-nats-mtls-subject-scoped-auth.md
│   │   └── 011-extract-python-orchestration-to-agamemnon.md
│   └── runbooks/
│       ├── add-new-host.md
│       ├── add-new-agent-type.md
│       └── disaster-recovery.md
├── e2e/                          # End-to-end Compose stacks + claude-myrmidon harness
├── tools/                        # Console scripts + GitHub helper CLIs (no submodules)
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
- When writing a new ADR: use `docs/adr/template.md` as the template, use the next sequential number, and set Status to "Proposed" until merged.
- Runbooks should be written as numbered steps that can be executed top-to-bottom without prior context.
- **ai-maestro has been fully removed per ADR-006.** ProjectAgamemnon replaces its task coordination role.

## Resource limits & concurrency on the `hermes` host

The dev/CI host (WSL2, hostname `hermes`) is bounded at **~16 GB RAM / 8 cores** (no `memory=`
cap in `.wslconfig`, so WSL sees ~50% of the ~32 GB Windows host). The two heaviest operations
here are **`pixi install`/`pixi lock`** (a conda+pypi SAT solve, ~0.5–1 GB RAM each) and
**C++ builds** (`cmake --build`, 1.5–3 GB + multi-core each). Running many of these at once will
exhaust RAM and the 16 GB swap, thrash, and **hang the whole WSL VM** (this has happened — a
16-repo Myrmidon fan-out with no throttle took the host down). Observe these limits:

- **≤3 concurrent heavy agents.** Do not fan out more than **3** background agents/sessions that
  each run `pixi`/`cmake`/`podman build` simultaneously. Prefer the harness `Workflow` primitive
  (it caps concurrency and queues the rest) or an explicit wave pattern over fire-and-forget
  parallel `Agent(run_in_background:true)` calls. `e2e/claude-myrmidon-multi.py` enforces this via
  `HERMES_MAX_CONCURRENT_AGENTS` (default 3).
- **Memory-bound heavy commands** with `ulimit -v` so an over-budget process fails recoverably
  instead of OOM-hanging the VM: `scripts/run-bounded.sh <cmd>` (default ~5 GiB cap), e.g.
  `scripts/run-bounded.sh pixi install`. Never run a large `pixi`/build/`pytest` unbounded in
  parallel.
- **Cap build parallelism**, don't use `-j$(nproc)` across concurrent agents. Set
  `ODYSSEUS_BUILD_JOBS=2` (the default in `scripts/install/50-cpp-builds.sh`) and/or
  `export CMAKE_BUILD_PARALLEL_LEVEL=2` so each build uses ≤2 cores.
- **Check headroom before scaling up:** run `free -h` before launching ≥4 heavy agents; if
  `available` is under ~6 GB or swap is in use, wait or reduce concurrency.
- Note: hephaestus' `max_workers=3` only bounds an in-process thread pool — it does **not** cap
  concurrent Claude agent *sessions*. The limits above are what actually protect the host.

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
