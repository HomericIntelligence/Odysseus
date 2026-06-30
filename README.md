# Odysseus

[![Build](https://github.com/HomericIntelligence/Odysseus/actions/workflows/build.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/build.yml)
[![CI](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ci.yml)
[![Ecosystem Health](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ecosystem-health.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ecosystem-health.yml)
[![Install Test](https://github.com/HomericIntelligence/Odysseus/actions/workflows/install-test.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/install-test.yml)
[![Release](https://github.com/HomericIntelligence/Odysseus/actions/workflows/release.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/release.yml)
[![Submodule Update Check](https://github.com/HomericIntelligence/Odysseus/actions/workflows/submodule-update-check.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/submodule-update-check.yml)

Odysseus is the meta-repo and unified architecture hub for the HomericIntelligence distributed agent mesh. It contains documentation, Architecture Decision Records (ADRs), shared configurations, runbooks, and all other HomericIntelligence repositories as git submodules.

## Purpose

Odysseus serves as the single source of truth for:
- System architecture and design decisions
- Cross-repo operational runbooks
- Shared infrastructure configurations (Nomad, NATS)
- Submodule references to every HomericIntelligence repo

## Quick Start

```bash
git clone --recurse-submodules https://github.com/HomericIntelligence/Odysseus.git
cd Odysseus
just bootstrap
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Documentation

Complete documentation is available in the [docs/](docs/) directory:

- **[Documentation Index](docs/README.md)** — Table of contents for all architecture, decisions, and operational guides
- **[System Architecture](docs/architecture.md)** — Complete overview of all components and interactions
- **[Architecture Decision Records](docs/adr/)** — All significant architectural decisions with rationale
- **[Operational Runbooks](docs/runbooks/)** — Step-by-step guides for common operational tasks
- **[NATS Subject Schema](docs/nats-subjects.md)** — Event bus subject patterns and streams
- **[Agent Safety Boundaries](AGENTS.md)** — Permitted tools, scope, off-limits files, and escalation paths for AI agents operating in this repo

## Repository Layout

```
Odysseus/
├── docs/
│   ├── README.md             # Documentation index and table of contents
│   ├── architecture.md       # Full system architecture overview
│   ├── adr/                  # Architecture Decision Records
│   └── runbooks/             # Operational runbooks
├── configs/
│   ├── nomad/                # Nomad client/server HCL configs
│   └── nats/                 # NATS server and leaf node configs
├── infrastructure/           # Submodules: AchaeanFleet, ProjectArgus, ProjectHermes
├── provisioning/             # Submodules: ProjectTelemachy, ProjectKeystone, Myrmidons
├── ci-cd/                    # Submodules: ProjectProteus
├── research/                 # Submodules: ProjectOdyssey, ProjectScylla
├── shared/                   # Submodules: ProjectMnemosyne, ProjectHephaestus
├── justfile
└── pixi.toml
```

### Ecosystem CI Status

| Repository | CI Status |
|---|---|
| [Odysseus](https://github.com/HomericIntelligence/Odysseus) | [![CI](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/Odysseus/actions/workflows/ci.yml) |
| [AchaeanFleet](https://github.com/HomericIntelligence/AchaeanFleet) | [![CI](https://github.com/HomericIntelligence/AchaeanFleet/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/AchaeanFleet/actions/workflows/ci.yml) |
| [ProjectArgus](https://github.com/HomericIntelligence/ProjectArgus) | [![CI](https://github.com/HomericIntelligence/ProjectArgus/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectArgus/actions/workflows/ci.yml) |
| [ProjectHermes](https://github.com/HomericIntelligence/ProjectHermes) | [![CI](https://github.com/HomericIntelligence/ProjectHermes/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectHermes/actions/workflows/ci.yml) |
| [ProjectAgamemnon](https://github.com/HomericIntelligence/ProjectAgamemnon) | [![Build & Test](https://github.com/HomericIntelligence/ProjectAgamemnon/actions/workflows/build-test.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectAgamemnon/actions/workflows/build-test.yml) |
| [ProjectNestor](https://github.com/HomericIntelligence/ProjectNestor) | [![Build & Test](https://github.com/HomericIntelligence/ProjectNestor/actions/workflows/build-test.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectNestor/actions/workflows/build-test.yml) |
| [ProjectTelemachy](https://github.com/HomericIntelligence/ProjectTelemachy) | [![CI](https://github.com/HomericIntelligence/ProjectTelemachy/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectTelemachy/actions/workflows/ci.yml) |
| [ProjectKeystone](https://github.com/HomericIntelligence/ProjectKeystone) | [![Release Please](https://github.com/HomericIntelligence/ProjectKeystone/actions/workflows/release-please.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectKeystone/actions/workflows/release-please.yml) |
| [Myrmidons](https://github.com/HomericIntelligence/Myrmidons) | [![Test](https://github.com/HomericIntelligence/Myrmidons/actions/workflows/test.yml/badge.svg)](https://github.com/HomericIntelligence/Myrmidons/actions/workflows/test.yml) |
| [ProjectProteus](https://github.com/HomericIntelligence/ProjectProteus) | [![CI](https://github.com/HomericIntelligence/ProjectProteus/actions/workflows/ci.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectProteus/actions/workflows/ci.yml) |
| [ProjectOdyssey](https://github.com/HomericIntelligence/ProjectOdyssey) | [![Build](https://github.com/HomericIntelligence/ProjectOdyssey/actions/workflows/build-validation.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectOdyssey/actions/workflows/build-validation.yml) |
| [ProjectScylla](https://github.com/HomericIntelligence/ProjectScylla) | [![Test](https://github.com/HomericIntelligence/ProjectScylla/actions/workflows/test.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectScylla/actions/workflows/test.yml) |
| [ProjectMnemosyne](https://github.com/HomericIntelligence/ProjectMnemosyne) | [![Validate Plugins](https://github.com/HomericIntelligence/ProjectMnemosyne/actions/workflows/validate-plugins.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectMnemosyne/actions/workflows/validate-plugins.yml) |
| [ProjectHephaestus](https://github.com/HomericIntelligence/ProjectHephaestus) | [![Test](https://github.com/HomericIntelligence/ProjectHephaestus/actions/workflows/test.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectHephaestus/actions/workflows/test.yml) |
| [ProjectCharybdis](https://github.com/HomericIntelligence/ProjectCharybdis) | [![Build & Test](https://github.com/HomericIntelligence/ProjectCharybdis/actions/workflows/build-test.yml/badge.svg)](https://github.com/HomericIntelligence/ProjectCharybdis/actions/workflows/build-test.yml) |

## Common Commands

| Command | Description |
|---|---|
| `just bootstrap` | Initialize and update all submodules |
| `just status` | Show status across all submodules |
| `just apply-all` | Apply Myrmidons declarative state via the Agamemnon API |
| `just update-submodules` | Pull latest commits for all submodules |
| `just hermes-start` | Start ProjectHermes event bridge |
| `just argus-start` | Start ProjectArgus observability stack |
| `just telemachy-run WORKFLOW` | Run a named workflow via ProjectTelemachy |

## Important Notes

- **ai-maestro has been removed per ADR-006.** All task coordination uses ProjectAgamemnon (`control/ProjectAgamemnon`, REST API at `$AGAMEMNON_URL`).
- See [docs/architecture.md](docs/architecture.md) for the current system architecture.
- See [docs/adr/](docs/adr/) for Architecture Decision Records.
