# Odysseus

Odysseus is the meta-repo and unified architecture hub for the HomericIntelligence distributed agent mesh. It contains documentation, Architecture Decision Records (ADRs), shared configurations, runbooks, and all other HomericIntelligence repositories as git submodules.

## Purpose

Odysseus serves as the single source of truth for:
- System architecture and design decisions
- Cross-repo operational runbooks
- Shared infrastructure configurations (Nomad, NATS)
- Submodule references to every HomericIntelligence repo

## Quick Start

```bash
git clone --recurse-submodules https://github.com/homeric-intelligence/Odysseus.git
cd Odysseus
just bootstrap
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Repository Layout

```
Odysseus/
├── docs/
│   ├── architecture.md       # Full system architecture overview
│   ├── adr/                  # Architecture Decision Records
│   └── runbooks/             # Operational runbooks
├── configs/
│   ├── nomad/                # Nomad client/server HCL configs
│   └── nats/                 # NATS server and leaf node configs
├── infrastructure/           # Submodules: ai-maestro, AchaeanFleet, ProjectArgus, ProjectHermes
├── provisioning/             # Submodules: ProjectTelemachy, ProjectKeystone, Myrmidons
├── ci-cd/                    # Submodules: ProjectProteus
├── research/                 # Submodules: ProjectOdyssey, ProjectScylla
├── shared/                   # Submodules: ProjectMnemosyne, ProjectHephaestus
├── justfile
└── pixi.toml
```

## Common Commands

| Command | Description |
|---|---|
| `just bootstrap` | Initialize and update all submodules |
| `just status` | Show status across all submodules |
| `just apply-all` | Apply Myrmidons declarative state to ai-maestro |
| `just update-submodules` | Pull latest commits for all submodules |
| `just hermes-start` | Start ProjectHermes event bridge |
| `just argus-start` | Start ProjectArgus observability stack |
| `just telemachy-run WORKFLOW` | Run a named workflow via ProjectTelemachy |

## Important Notes

- **Do not modify the `infrastructure/ai-maestro` submodule.** ai-maestro is an external dependency managed upstream. All integration is via its REST API and webhooks only.
- All new features belong in their respective new repos, never in ai-maestro.
