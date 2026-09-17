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

### Optional (for operator-approved multi-host scenarios)

1. **Tailscale** — VPN mesh for cross-host communication. It is not required
   for local development or CI. [Installation](https://tailscale.com/download)

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

## Ecosystem Overview: The Repositories

HomericIntelligence is a distributed system built from 16 canonical
repositories: Odysseus plus the 15 component gitlinks in `.gitmodules`.
**Odysseus** is the top-level meta-repo that coordinates them all. The list
below is complete at this revision; see [`docs/architecture.md`](architecture.md)
for the component roles and current-versus-proposed architecture boundary.

### The Big Picture

```
User
  ↓ (bidirectional interaction)
Odysseus (meta-repo, orchestration hub)
  ├─→ Agamemnon (control plane, task coordination)
  ├─→ Nestor (research-request intake & status)
  ├─→ Keystone (in-process MessageBus and optional NATS bridge)
  ├─→ Argus (observability)
  ├─→ Hermes (signed webhook ingestion)
  ├─→ AchaeanFleet (AI-agent base/vessel images)
  ├─→ Myrmidons (agent fleet & GitOps)
  ├─→ Telemachy (workflow engine)
  ├─→ Proteus (CI/CD pipelines)
  ├─→ Charybdis (chaos testing)
  ├─→ Scylla (ablation benchmarks)
  ├─→ Odyssey (standalone Mojo ML research)
  ├─→ Mnemosyne (shared memory)
  ├─→ Athena (public athena@Athena plugin; pinned revision has 14 skills)
  └─→ Hephaestus (shared runtime and automation utilities)
```

### Quick Reference: What Each Repo Does

| Repo | Category | Role | Language | Status |
|------|----------|------|----------|--------|
| **Odysseus** | meta | User interface, observability hub, meta-repo | Markdown, Bash, Python | You are here |
| **Agamemnon** | control | Task planning and HMAS orchestration; in-memory store by default, optional GitHub Issues write-through | C++, Python | Core system |
| **Nestor** | control | C++20 research-request intake and status service | C++ | Core system |
| **Keystone** | transport | In-process MessageBus and optional NATS bridge | C++ | Core system |
| **Argus** | infrastructure | Metrics (Prometheus), logs (Loki), dashboards (Grafana) | Go, Python | Observability |
| **Hermes** | infrastructure | Signed webhook ingestion and NATS publication; no outbound or email implementation | Python | Bridge |
| **AchaeanFleet** | infrastructure | AI-agent base and vessel image definitions | Dockerfile, OCI | Build artifacts |
| **Myrmidons** | provisioning | Agent fleet YAML manifests (GitOps source of truth) | YAML | Config |
| **Telemachy** | provisioning | Declarative workflow engine | Python | Internal tool |
| **Proteus** | ci-cd | Build pipelines (Dagger TypeScript) | TypeScript | Automation |
| **Charybdis** | testing | Chaos and resilience testing | C++, Python | Testing |
| **Scylla** | testing | AI agent ablation and benchmarking | Python, Mojo | Research |
| **Odyssey** | research | Standalone Mojo ML training framework | Mojo | Research |
| **Mnemosyne** | shared | Knowledge store/backend for Athena `advise` and `learn` | Python | Utility |
| **Hephaestus** | shared | Shared runtime utilities and optional automation product layer | Python, TypeScript | Utility |
| **Athena** | agentic | Public `athena@Athena` plugin; pinned revision has 14 root skill routers, while the planned release preserves 17 IDs | Python | Utility |

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

All 15 component repositories are checked in as git submodules. Initialize
them:

```bash
just bootstrap
```

This runs `git submodule update --init --recursive`. **Always do this after cloning.**

You can verify submodules are present:

```bash
ls -la agentic/ control/ provisioning/ infrastructure/ ci-cd/ research/ testing/ shared/
```

### 3. Install Project Dependencies

Install the Odysseus root toolchain:

```bash
pixi install
```

This creates the root Pixi environment. Each component owns its own dependency
setup; follow that component's README and lockfile.

### 4. Build (Optional, but Recommended)

Build the targets selected by the root `build` recipe:

```bash
just build
```

Artifacts land in `build/<submodule-name>/`. This is useful for testing locally before pushing.

### 5. Make Changes

Make component changes in an isolated worktree of the component's own
repository. Treat the component worktrees inside Odysseus as read-only
integration references.

Examples:

- Fixing a bug in Agamemnon → edit `/path/to/Agamemnon/src/...`
- Adding a runbook → edit `docs/runbooks/...` in Odysseus
- Adding an agent template → edit `/path/to/Myrmidons/agents/_templates/...` in
  an isolated Myrmidons worktree

### 6. Test Locally

Use the individual component test suites. Start with `just --list` and the
component README. Prefer a checked-in `just` or `pixi run` entry point when one
exists; invoke a script directly only when the repository documents that path
or has no wrapper for it.

### 7. Commit and Push

Start from the component's freshly fetched remote commit, record the immutable
SHA, and create a separate worktree. Do not implement inside the component
checkout embedded in Odysseus. For example:

```bash
git -C /path/to/Agamemnon fetch origin main
git -C /path/to/Agamemnon rev-parse --verify 'origin/main^{commit}'
git -C /path/to/Agamemnon worktree add \
  -b 123-fix-agent-startup \
  /path/to/worktrees/Agamemnon-123 \
  <verified-origin-main-SHA>
cd /path/to/worktrees/Agamemnon-123
git add <specific-files>
git commit -m "feat: description of change

Details...

Co-Authored-By: Your Name <your.email@example.com>"
git push -u origin 123-fix-agent-startup
```

**Important:** Never use `git add .` or `git add -A`. Always stage specific files to avoid committing sensitive configs or build artifacts.

### 8. Create a Pull Request

```bash
gh pr create --title "feat: short description" --body "Detailed description..."
```

See `docs/adr/` for architectural decisions and ADR format if your change crosses repo boundaries.

### 9. Code Review

A maintainer reviews your PR. Address feedback and push additional commits (do
not force-push). Before merge, the exact current head must complete the bounded
`athena:pr-review` exchange with terminal `GO`, and every live required CI/CD
check must succeed.

### 10. Merge

Once the exact-head Athena and CI/CD gates above pass, read the live repository
settings and select a method that is enabled at that time. Add `--auto` only
when the readback says auto-merge is enabled:

```bash
gh api repos/HomericIntelligence/Odysseus \
  --jq '{allow_auto_merge,allow_merge_commit,allow_rebase_merge,allow_squash_merge}'
PR_URL=https://github.com/HomericIntelligence/Odysseus/pull/NUMBER
MERGE_FLAG=--squash  # example only: select the flag authorized by the readback
gh pr merge "$PR_URL" "$MERGE_FLAG"
```

---

## Key Commands

The root `justfile` is the front door for the tasks it exposes. See the full
list:

```bash
just --list
```

### Common Tasks

| Command | What It Does |
|---------|--------------|
| `just bootstrap` | Initialize all 15 component git submodules |
| `just status` | Show git status across all submodules |
| `just build` | Build the root-supported component and example targets |
| `just setup` | One-command setup (bootstrap + build) |
| `just argus-start` | Report why pinned Argus activation is unavailable |
| `just install /usr/local` | Install the four CMake server/library targets to a prefix |

Component-owned build, test, workflow, and deployment recipes run from an
isolated checkout of that component after its own contract and exact revision
have been verified. Odysseus does not proxy mutable submodule `justfile`
content.

---

## Where to Find What

### Architecture & Design

- **System Overview** → `docs/architecture.md`
- **Architectural Decisions** → `docs/adr/` (numbered ADRs; Accepted ADRs are
  append-only and never edited)
- **Component Relationships** → `docs/architecture.md` (component inventory and system diagram)

### Deployment & Operations

- **Deployment Guide** → `docs/deployment.md` (end-to-end fresh ecosystem setup)
- **Runbooks** → `docs/runbooks/` (step-by-step operations guides)
  - `add-new-host.md` — Scale the mesh to new hosts
  - `add-new-agent-type.md` — Create custom agent types
  - `disaster-recovery.md` — Backup and recovery procedures
  - `wsl2-podman-setup.md` — Windows WSL2 Podman configuration

### Development

- **Project Structure** → root `README.md` and this guide
- **Agent operating boundaries** → `AGENTS.md`
- **CI/CD Pipelines** → `ci-cd/Proteus/` (Dagger TypeScript)
- **E2E Tests** → `e2e/` (integration and topology tests)
- E2E scenario coverage is mapped in [`e2e/tests/README.md`](../e2e/tests/README.md)
  (generated from each test's header). After adding or editing a test, run
  `python3 e2e/tools/gen_test_matrix.py`; CI (`unit-tests`) fails if it is stale
  or a header is non-conforming.

### Configuration

- **NATS Server Config** → `configs/nats/server.conf`
- **Nomad Server Config** → `configs/nomad/server.hcl`
- **Nomad Client Config** → `configs/nomad/client.hcl`

### Submodule Repos (Detailed Information)

Each submodule has its own `README.md`. Start there for specifics:

- `control/Agamemnon/README.md`
- `control/Nestor/README.md`
- etc.

---

## Typical Development Scenarios

### Scenario 1: Fix a Bug in Agamemnon

```bash
# From a separate Agamemnon clone, bind the current remote commit and create
# an isolated component worktree as described in Step 7.
git -C /path/to/Agamemnon fetch origin main
git -C /path/to/Agamemnon rev-parse --verify 'origin/main^{commit}'
git -C /path/to/Agamemnon worktree add \
  -b 123-fix-agamemnon-bug \
  /path/to/worktrees/Agamemnon-123 \
  <verified-origin-main-SHA>
cd /path/to/worktrees/Agamemnon-123
# ... make changes ...

# Test it (see Agamemnon's README for test commands)
# ... run tests ...

# Commit the component change on its own branch
git add <specific-files>
git commit -m "fix(agamemnon): describe the bug fix"
git push -u origin 123-fix-agamemnon-bug

# Create PR
gh pr create --title "fix(agamemnon): ..." --body "..."

# Pinning the merged component in Odysseus is a separate integration PR
```

### Scenario 2: Add a New Runbook

```bash
# From the Odysseus clone, bind the current remote commit and create an
# isolated root worktree.
git fetch origin main
git rev-parse --verify 'origin/main^{commit}'
git worktree add \
  -b 124-add-operator-runbook \
  /path/to/worktrees/Odysseus-124 \
  <verified-origin-main-SHA>
cd /path/to/worktrees/Odysseus-124

# Add the runbook
$EDITOR docs/runbooks/my-runbook.md

# Commit
git add docs/runbooks/my-runbook.md
git commit -m "docs: add runbook for my operation"
git push -u origin 124-add-operator-runbook

# Create PR
gh pr create --title "docs: add runbook for my operation"
```

### Scenario 3: Update a Submodule Pin (After a Release)

Submodule pin changes are cross-repository integration events. Do not move a
component checkout inside Odysseus as part of ordinary component work. After
the component change has merged, the integration owner obtains explicit
approval for the exact commit, updates the gitlink in a dedicated
`<issue-number>-<short-slug>` Odysseus branch, and runs the integration checks.

---

## Important Principles

### 1. Odysseus is Read-Mostly

Most changes happen in the individual submodule repos, not in Odysseus. Odysseus itself contains:

- ADRs (architecture decisions)
- Runbooks (operational procedures)
- Canonical configs (NATS, Nomad)
- Submodule pins (as git submodules)
- Integration scripts, E2E harnesses, and the operator console

Component service implementations live in the component repositories.

### 2. ADRs Are Append-Only

Once an ADR is Accepted, it is never edited. Proposed ADRs are not binding and
may change during review. If an accepted decision changes, write a new ADR that
references the old one. See `docs/adr/006-decouple-from-ai-maestro.md` for an
example.

### 3. Configs Are Canonical

The NATS and Nomad source configs in `configs/` are canonical. Deployment may
render or copy them to host-specific locations; compare live state with the
source rather than assuming a host mount or symlink is current.

### 4. Submodule Pins Matter

The git submodule SHAs checked into this repo represent the last known-good cross-repo integration point. Update them deliberately and test the full system before committing.

### 5. Use the Checked-In Task Front Door

Run `just --list` first and use a repository-owned `just` recipe when it covers
the task. Use `pixi run` where the checked-in Pixi environment owns the tool.
Some maintained operations intentionally expose only a direct script; follow
the local README or runbook in that case. Never invent a wrapper or claim a
recipe succeeded when it is absent.

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
rg "<term>" control/ provisioning/ infrastructure/
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
2. **Read a Submodule README** — Pick one that interests you (e.g., Agamemnon).
3. **Run `just bootstrap` and `just build`** — Get it running locally.
4. **Pick a Small Issue** — Find a good-first-issue and fix it.
5. **Join the Discussion** — Open a PR and engage with the team.

---

## Quick Reference: Submodule Paths

```
control/
├── Agamemnon          # Task planning, orchestration
└── Nestor             # Research-request intake and status

provisioning/
├── Telemachy          # Workflow engine
├── Keystone           # Transport layer
└── Myrmidons                 # Agent fleet (GitOps)

infrastructure/
├── AchaeanFleet              # AI-agent base/vessel images
├── Argus              # Observability
└── Hermes             # Signed webhook ingestion

ci-cd/
└── Proteus            # Build pipelines

research/
├── Odyssey            # ML sandbox
└── Scylla             # Ablation benchmarks

testing/
└── Charybdis          # Chaos testing

agentic/
└── Athena                     # Public athena@Athena plugin and skill routers

shared/
├── Mnemosyne                  # Knowledge store/backend
└── Hephaestus                 # Shared runtime + automation utilities
```

---

## Welcome

You're now ready to contribute to HomericIntelligence. Start small, ask questions, and enjoy building distributed AI systems!
