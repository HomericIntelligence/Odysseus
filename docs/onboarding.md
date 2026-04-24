# Developer Onboarding Guide

Welcome to the HomericIntelligence ecosystem. This guide introduces the system architecture, development workflow, and key commands to get you productive quickly.

---

## What You Need to Install

Before starting, ensure you have these tools installed:

### Required

1. **Git** — Version control. [Installation](https://git-scm.com/downloads)

2. **Pixi** — Package manager for Python environments. [Installation](https://pixi.sh/latest/#installation)

   ```bash
   curl -fsSL https://pixi.sh/install.sh | bash
   ```

3. **Just** — Task runner (like Make, but better). [Installation](https://github.com/casey/just)

   ```bash
   # macOS:
   brew install just
   
   # Linux (via Cargo):
   cargo install just
   ```

4. **Podman** — Container runtime (Docker alternative). [Installation](https://podman.io/docs/installation)

   ```bash
   # Debian/Ubuntu:
   sudo apt-get install podman
   
   # RHEL/Fedora:
   sudo dnf install podman
   ```

### Highly Recommended (for local testing and multi-host scenarios)

5. **Tailscale** — VPN mesh for cross-host communication. [Installation](https://tailscale.com/download)

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   ```

Verify all installations:

```bash
git --version
pixi --version
just --version
podman --version
```

---

## Ecosystem Overview: The 12 Repositories

HomericIntelligence is a distributed system built from 12 specialized repositories. **Odysseus** is the top-level meta-repo that coordinates them all.

### The Big Picture

```
User
  ↓ (bidirectional interaction)
Odysseus (meta-repo, orchestration hub)
  ├─→ ProjectAgamemnon (control plane, task coordination)
  ├─→ ProjectNestor (research & ideation)
  ├─→ ProjectKeystone (transport/event bus)
  ├─→ ProjectArgus (observability)
  ├─→ ProjectHermes (external integrations)
  ├─→ AchaeanFleet (container images)
  ├─→ Myrmidons (agent fleet & GitOps)
  ├─→ ProjectTelemachy (workflow engine)
  ├─→ ProjectProteus (CI/CD pipelines)
  ├─→ ProjectCharybdis (chaos testing)
  ├─→ ProjectScylla (ablation benchmarks)
  ├─→ ProjectMnemosyne (shared memory)
  └─→ ProjectHephaestus (shared utilities & skills)
```

### Quick Reference: What Each Repo Does

| Repo | Category | Role | Language | Status |
|------|----------|------|----------|--------|
| **Odysseus** | meta | User interface, observability hub, meta-repo | Markdown, Bash | You are here |
| **ProjectAgamemnon** | control | Task planning, HMAS orchestration, GitHub-backed | C++, Python | Core system |
| **ProjectNestor** | control | Research, ideation, multi-step workflows | Python, C++ | Core system |
| **ProjectKeystone** | transport | Event bus (BlazingMQ intra-host, NATS cross-host) | C++ | Core system |
| **ProjectArgus** | infrastructure | Metrics (Prometheus), logs (Loki), dashboards (Grafana) | TypeScript, Python | Observability |
| **ProjectHermes** | infrastructure | Slack, GitHub, email integrations | Python | Bridge |
| **AchaeanFleet** | infrastructure | Container image registry and definitions | Dockerfile, OCI | Build artifacts |
| **Myrmidons** | provisioning | Agent fleet YAML manifests (GitOps source of truth) | YAML | Config |
| **ProjectTelemachy** | provisioning | Declarative workflow engine | Python, C++ | Internal tool |
| **ProjectProteus** | ci-cd | Build pipelines (Dagger TypeScript) | TypeScript | Automation |
| **ProjectCharybdis** | testing | Chaos and resilience testing | Python | Testing |
| **ProjectScylla** | testing | AI agent ablation and benchmarking | Python, Mojo | Research |
| **ProjectMnemosyne** | shared | Memory store for `advise` and `learn` plugins | Python | Utility |
| **ProjectHephaestus** | shared | Shared utilities, Claude Code plugins | Python, TypeScript | Utility |

---

## Developer Workflow

### 1. Fork and Clone

Fork Odysseus on GitHub (if contributing upstream):

```bash
git clone https://github.com/<your-username>/Odysseus.git
cd Odysseus
```

Or clone the canonical repo:

```bash
git clone https://github.com/HomericIntelligence/Odysseus.git
cd Odysseus
```

### 2. Initialize Submodules

All 12 repos are checked in as git submodules. Initialize them:

```bash
just bootstrap
```

This runs `git submodule update --init --recursive`. **Always do this after cloning.**

You can verify submodules are present:

```bash
ls -la control/ provisioning/ infrastructure/ ci-cd/ research/ testing/ shared/
```

### 3. Install Project Dependencies

Install Python environment and dependencies:

```bash
pixi install
```

This creates a project-local Python environment with all transitive dependencies resolved.

### 4. Build (Optional, but Recommended)

Build all compilable submodules:

```bash
just build
```

Artifacts land in `build/<submodule-name>/`. This is useful for testing locally before pushing.

### 5. Make Changes

Edit files in any submodule. Most day-to-day changes happen in the individual submodule repos, not in Odysseus itself.

Examples:

- Fixing a bug in ProjectAgamemnon → edit `control/ProjectAgamemnon/src/...`
- Adding a runbook → edit `docs/runbooks/...` in Odysseus
- Adding an agent template → edit `provisioning/Myrmidons/templates/...`

### 6. Test Locally

Use the individual submodule test suites. See each repo's README for testing instructions.

For integration testing, use `just` tasks or the e2e scripts in `e2e/`.

### 7. Commit and Push

Create a branch and push:

```bash
git checkout -b feature/my-feature
git add <specific-files>
git commit -m "feat: description of change

Details...

Co-Authored-By: Your Name <your.email@example.com>"
git push -u origin feature/my-feature
```

**Important:** Never use `git add .` or `git add -A`. Always stage specific files to avoid committing sensitive configs or build artifacts.

### 8. Create a Pull Request

```bash
gh pr create --title "feat: short description" --body "Detailed description..."
```

See `docs/adr/` for architectural decisions and ADR format if your change crosses repo boundaries.

### 9. Code Review

A maintainer reviews your PR. Address feedback and push additional commits (do not force-push).

### 10. Merge

Once approved, the PR is merged via rebase:

```bash
gh pr merge --auto --rebase
```

---

## Key Commands

All tasks are orchestrated via `just`. See the full list:

```bash
just --list
```

### Common Tasks

| Command | What It Does |
|---------|--------------|
| `just bootstrap` | Initialize all 12 git submodules |
| `just status` | Show git status across all submodules |
| `just build` | Build all C++/CMake/Mojo components |
| `just setup` | One-command setup (bootstrap + build) |
| `just update-submodules` | Pull latest from all upstream submodule remotes |
| `just agamemnon-start` | Start ProjectAgamemnon (control plane) |
| `just nestor-start` | Start ProjectNestor (research service) |
| `just keystone-start` | Start ProjectKeystone (event bus) |
| `just hermes-start` | Start ProjectHermes (external bridge) |
| `just argus-start` | Start ProjectArgus (observability stack) |
| `just apply-all` | Deploy Myrmidons YAML manifests via Agamemnon |
| `just telemachy-run WORKFLOW=<name>` | Execute a named workflow |
| `just install PREFIX=/usr/local` | Install all binaries to a prefix |

---

## Where to Find What

### Architecture & Design

- **System Overview** → `docs/architecture.md`
- **Architectural Decisions** → `docs/adr/` (numbered ADRs, append-only, never edited)
- **Component Relationships** → `docs/architecture.md` (component inventory and system diagram)

### Deployment & Operations

- **Deployment Guide** → `docs/deployment.md` (end-to-end fresh ecosystem setup)
- **Runbooks** → `docs/runbooks/` (step-by-step operations guides)
  - `add-new-host.md` — Scale the mesh to new hosts
  - `add-new-agent-type.md` — Create custom agent types
  - `disaster-recovery.md` — Backup and recovery procedures
  - `wsl2-podman-setup.md` — Windows WSL2 Podman configuration

### Development

- **Project Structure** → `CLAUDE.md` (repo layout and development guidelines)
- **CI/CD Pipelines** → `ci-cd/ProjectProteus/` (Dagger TypeScript)
- **E2E Tests** → `e2e/` (integration and topology tests)

### Configuration

- **NATS Server Config** → `configs/nats/server.conf`
- **Nomad Server Config** → `configs/nomad/server.hcl`
- **Nomad Client Config** → `configs/nomad/client.hcl`

### Submodule Repos (Detailed Information)

Each submodule has its own `README.md`. Start there for specifics:

- `control/ProjectAgamemnon/README.md`
- `control/ProjectNestor/README.md`
- etc.

---

## Typical Development Scenarios

### Scenario 1: Fix a Bug in ProjectAgamemnon

```bash
# Clone and setup
git clone https://github.com/HomericIntelligence/Odysseus.git
cd Odysseus
just bootstrap
just build

# Create a feature branch
git checkout -b fix/agamemnon-bug

# Edit the source (it's checked in as a submodule)
cd control/ProjectAgamemnon
# ... make changes ...
cd ../..

# Test it (see ProjectAgamemnon's README for test commands)
# ... run tests ...

# Commit the submodule update
git add control/ProjectAgamemnon
git commit -m "fix(agamemnon): describe the bug fix"
git push -u origin fix/agamemnon-bug

# Create PR
gh pr create --title "fix(agamemnon): ..." --body "..."
```

### Scenario 2: Add a New Runbook

```bash
# Create a feature branch
git checkout -b docs/new-runbook

# Add the runbook
cat > docs/runbooks/my-runbook.md << 'EOF'
# Runbook: My Operation

## Prerequisites
...

## Steps

### 1. Do this

### 2. Do that

...
EOF

# Commit
git add docs/runbooks/my-runbook.md
git commit -m "docs: add runbook for my operation"
git push -u origin docs/new-runbook

# Create PR
gh pr create --title "docs: add runbook for my operation"
```

### Scenario 3: Update a Submodule Pin (After a Release)

```bash
# Create a feature branch
git checkout -b chore/bump-submodules

# Pull latest upstream
just update-submodules

# Verify everything still works
just build
just status

# Commit the new pins
git add control/ provisioning/ infrastructure/ ci-cd/ research/ testing/ shared/
git commit -m "chore: bump submodule pins to latest origin/main"
git push -u origin chore/bump-submodules

# Create PR
gh pr create --title "chore: bump submodule pins to latest origin/main"
```

---

## Important Principles

### 1. Odysseus is Read-Mostly

Most changes happen in the individual submodule repos, not in Odysseus. Odysseus itself contains:

- ADRs (architecture decisions)
- Runbooks (operational procedures)
- Canonical configs (NATS, Nomad)
- Submodule pins (as git submodules)

**Application code lives in the submodules.**

### 2. ADRs Are Append-Only

Once an ADR is merged, it is never edited. If a decision changes, write a new ADR that references the old one. See `docs/adr/006-decouple-from-ai-maestro.md` for an example.

### 3. Configs Are Canonical

The NATS and Nomad configs in `configs/` are the authoritative source. Hosts copy or symlink from here, never diverge locally.

### 4. Submodule Pins Matter

The git submodule SHAs checked into this repo represent the last known-good cross-repo integration point. Update them deliberately and test the full system before committing.

### 5. Use Just, Not Direct Scripts

Always use `just` tasks instead of running scripts directly. This ensures consistency and documentation.

---

## Getting Help

### Read the Docs

1. **Architecture**: `docs/architecture.md`
2. **Deployment**: `docs/deployment.md`
3. **Runbooks**: `docs/runbooks/`
4. **ADRs**: `docs/adr/`
5. **Individual Submodule READMEs**: `<path>/<repo>/README.md`

### Check Existing Code

All repos are well-commented. Search before asking:

```bash
git log --all --grep="<keyword>"
grep -r "<term>" control/ provisioning/ infrastructure/
```

### Ask in Issues

If you're stuck, open an issue on GitHub describing:

1. What you were trying to do
2. What happened
3. The full error message
4. Your OS and tool versions (`git --version`, `pixi --version`, etc.)

---

## Next Steps

1. **Read `docs/architecture.md`** — Understand the full system.
2. **Read a Submodule README** — Pick one that interests you (e.g., ProjectAgamemnon).
3. **Run `just bootstrap` and `just build`** — Get it running locally.
4. **Pick a Small Issue** — Find a good-first-issue and fix it.
5. **Join the Discussion** — Open a PR and engage with the team.

---

## Quick Reference: Submodule Paths

```
control/
├── ProjectAgamemnon          # Task planning, orchestration
└── ProjectNestor             # Research, ideation

provisioning/
├── ProjectTelemachy          # Workflow engine
├── ProjectKeystone           # Transport layer
└── Myrmidons                 # Agent fleet (GitOps)

infrastructure/
├── AchaeanFleet              # Container images
├── ProjectArgus              # Observability
└── ProjectHermes             # External integrations

ci-cd/
└── ProjectProteus            # Build pipelines

research/
├── ProjectOdyssey            # ML sandbox
└── ProjectScylla             # Ablation benchmarks

testing/
└── ProjectCharybdis          # Chaos testing

shared/
├── ProjectMnemosyne          # Memory store
└── ProjectHephaestus         # Shared utilities
```

---

## Welcome!

You're now ready to contribute to HomericIntelligence. Start small, ask questions, and enjoy building distributed AI systems!
