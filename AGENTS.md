# AGENTS.md — Odysseus

> **AI agents:** This file is the sole authoritative agent contract for this
> repository. It defines the behavioral contract for AI agents operating here —
> read this before taking any action. [CLAUDE.md](CLAUDE.md) is a pointer to
> this file.

## Audience

This document governs the following AI agent runtimes operating in Odysseus:

- **Claude Code myrmidons** — Claude CLI instances launched by `e2e/claude-myrmidon.py`
  inside the `achaean-claude` container
- **Agamemnon planner** — the HMAS planning/orchestration agent (`control/Agamemnon`)
- **Nestor researcher** — the research and ideation agent (`control/Nestor`)

Human contributors: the Project Overview, Development Guidelines, and Common
Commands sections below apply to you as well.

---

## Project Overview

Odysseus is the meta-repo and unified architecture hub for the HomericIntelligence distributed agent mesh. It is the top-level entry point for the entire ecosystem: it holds Architecture Decision Records, operational runbooks, shared infrastructure configs, and references every other HomericIntelligence repository as a git submodule.

Odysseus holds the Fleet web application in `web/` as well as system coordination documentation. The web backend projects supported component interfaces and transport observations; it does not become another orchestration authority. Engineers and agents starting here can understand the system, find every component, and perform cross-cutting operations with a single `just` command.

---

## Key Principles

1. **Odysseus is read-mostly.** Most day-to-day changes happen in the individual submodule repos, not here.
2. **ai-maestro has been removed per ADR-006.** Agamemnon (control/Agamemnon) replaces ai-maestro's task coordination role.
3. **ADRs are append-only.** Once an ADR is accepted it is never edited. Superseding decisions get a new ADR that references the old one.
4. **Configs here are canonical.** The Nomad and NATS configs in `configs/` are the authoritative source. Individual hosts copy or symlink from here.
5. **Submodule pins matter.** The submodule SHAs in this repo represent the last known-good cross-repo integration point.

---

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
│   ├── Argus
│   └── Hermes
├── control/                      # git submodules
│   ├── Agamemnon          # Planning + HMAS orchestration (replaces ai-maestro)
│   └── Nestor             # Research, ideation, handoff to Agamemnon
├── provisioning/                 # git submodules
│   ├── Telemachy
│   ├── Keystone
│   └── Myrmidons
├── ci-cd/                        # git submodules
│   └── Proteus
├── research/                     # git submodules
│   ├── Odyssey
│   └── Scylla
├── testing/                      # git submodules
│   └── Charybdis          # Chaos/resilience testing via Agamemnon /v1/chaos/*
├── shared/                       # git submodules
│   ├── Mnemosyne
│   └── Hephaestus
├── .gitmodules
├── AGENTS.md                     # This file — the authoritative agent contract
├── CLAUDE.md                     # Pointer to AGENTS.md
├── justfile
└── pixi.toml
```

---

## Scope

### In scope — agents may read and write

| Area | Read | Write | Notes |
|------|------|-------|-------|
| `docs/` (non-ADR) | Yes | Yes | Architecture, runbooks, onboarding docs |
| `docs/adr/` (proposed ADRs) | Yes | Yes | Only ADRs with Status: Proposed |
| `docs/adr/` (accepted ADRs) | Yes | **No** | Append-only — see Prohibited Actions |
| `configs/nomad/` | Yes | Coordinate | Canonical — coordinate before editing |
| `configs/nats/` | Yes | Coordinate | Canonical — coordinate before editing |
| `e2e/` | Yes | Yes | Pipeline harness and Compose stacks |
| `tools/` | Yes | Yes | Console scripts and GitHub helper CLIs |
| `web/` | Yes | Yes | Odysseus web application, component interface adapters, and focused tests; no separate task authority |
| `scripts/` | Yes | Yes | Validation and utility scripts |
| `justfile` | Yes | Yes | Task execution entry points |
| `pixi.toml` | Yes | Coordinate | Dependency manifest — coordinate before editing |
| `.github/workflows/` | Yes | **No** | Requires human review before any edit |
| `.gitmodules` | Yes | **No** | Submodule pins require integration sign-off |
| Submodule working trees | Yes | **No** | Changes belong in each submodule's own repo |
| Any file at repo root | Yes | Yes | README, CLAUDE.md, AGENTS.md, etc. |

### Out of scope — agents must not touch

- **Accepted ADRs** (`docs/adr/00*.md` with `Status: Accepted`) — append-only invariant
  per Key Principles item 3 above. Write a new superseding ADR instead.
- **Submodule working trees** from the meta-repo — changes must go through each
  submodule's own repository and PR process.
- **Submodule SHA pins** (`.gitmodules`, `git submodule update`) — bumping a pin
  constitutes a cross-repo integration event requiring explicit approval.
- **`.github/workflows/`** — CI pipeline changes require human review.
- **Secrets, credentials, API keys** — never commit `.env`, `AGAMEMNON_API_KEY`, or
  any credential to the repository.

---

## Permitted Actions

The following actions are authorized for myrmidon agents, grounded in
`e2e/claude-myrmidon.py`:

### Permitted tools

```
Bash, Read, Write, Edit, Glob, Grep
```

Source: `e2e/claude-myrmidon.py:259` — `--allowedTools Bash,Read,Write,Edit,Glob,Grep`

### Permitted CLI operations

- `gh issue view`, `gh issue comment` — read issues and post progress updates
  (`e2e/claude-myrmidon.py:380`)
- `gh pr create`, `gh pr merge --auto --rebase` — open PRs and enable auto-merge
  (`e2e/claude-myrmidon.py:695–701`)
- `git add`, `git commit` — stage and commit changes on a feature branch
- `git push -u origin <branch>` — push a feature branch (never `main` or `--force`)
- `just <recipe>`, `pixi run <task>` — task execution (this contract mandates these
  over direct script invocation)
- `markdownlint <file>` — validate markdown before committing

### Permitted repository operations

- Create feature branches named `<issue-number>-<slug>`
- Open a PR targeting `main` with `Closes #<issue>` in the body
- Enable auto-merge (`--auto --rebase`) on the agent's own PR
- Comment on the issue being worked with status updates

---

## Prohibited Actions

The following actions are unconditionally prohibited:

- **Edit an accepted ADR** — `docs/adr/00*.md` (Status: Accepted) are append-only.
  Write a new ADR with the next sequential number that references the old one.
- **Bump submodule pins** — do not modify `.gitmodules` or run
  `git submodule update --remote` without explicit cross-repo integration approval.
- **Reference or re-introduce ai-maestro** — fully removed per ADR-006;
  Agamemnon is the replacement.
- **Commit secrets** — never commit `.env`, API keys, `AGAMEMNON_API_KEY`,
  `GITHUB_TOKEN`, or any credential.
- **Force-push** — `git push --force` and `git push --force-with-lease` are prohibited
  on all branches.
- **Skip hooks** — never pass `--no-verify` to git commands.
- **Edit `.github/workflows/`** without a human reviewer approving the change.
- **Edit canonical configs without coordination** — `configs/nomad/` and `configs/nats/`
  are the authoritative source for all hosts; edits without coordination can break
  production deployments.
- **Operate outside the container** with `--dangerously-skip-permissions` — see the
  policy section below.
- **Fabricate evidence** — never hand-write, edit, or commit a log, metric, test
  result, benchmark, or training-run output that was not produced by actually
  executing the run. See the Evidence & Integrity Policy below.

---

## Evidence & Integrity Policy

Per [ADR-014](docs/adr/014-runnable-evidence-for-metric-claims.md). This policy is
binding on every agent (Nestor, Agamemnon, Myrmidon, and any host-side session).

**The governing rule: a truthful failure is acceptable; invented success is not.**
An agent that reports "the run did not complete in the available window" has
satisfied the integrity requirement. An agent that reports a metric it did not
measure has violated it, no matter how plausible the number.

1. **Never fabricate.** Do not hand-author or edit a log, metric, accuracy,
   loss, test result, or benchmark to represent output of a run that did not
   actually happen. Plausible-looking invented numbers are the failure, not a
   shortcut around it.

2. **A committed log is not evidence.** A file you commit into a PR (e.g.
   `validation/epoch1.log`) carries zero evidentiary weight. Genuine evidence is
   output produced by a gate you do not author — a CI-produced artifact or an
   independently re-executed run — pasted verbatim.

3. **Decouple slow runs from in-session deliverables.** If honest completion of
   a task requires a run longer than your session/timeout budget, do **not**
   report the run's *result* as done. Deliver the code and a runnable command;
   the run is a separate, sanctioned detached-execution step, and its verbatim
   output (or a truthful non-completion record) is committed by a follow-up
   evidence-collection task.

4. **When blocked, say so.** If you cannot obtain a required measurement,
   report the blocker plainly (what you tried, why it did not finish). Do not
   fill the gap with fiction. Escalate to a human operator.

Forensic note for reviewers: fabricated metrics tend to show tells the genuine
code cannot produce — e.g. uniform fixed-decimal losses where the code prints
full `String(Float32)` precision, monotone evenly-spaced loss curves, or a
"completed" artifact timestamped before any run could have finished.

---

## `--dangerously-skip-permissions` Policy

The myrmidon pipeline runs Claude Code with `--dangerously-skip-permissions`
**exclusively inside the ephemeral `achaean-claude` container**
(`e2e/claude-myrmidon.py:228, 258`).

Compensating controls in place:

1. **Containerized** — the `achaean-claude` image is an isolated, ephemeral runtime;
   the host filesystem is not directly accessible.
2. **Scoped tool allowlist** — `--allowedTools Bash,Read,Write,Edit,Glob,Grep` restricts
   which tools the agent can call (`e2e/claude-myrmidon.py:259`).
3. **Timeout** — the container session is hard-limited to 1800 seconds
   (`e2e/claude-myrmidon.py:282`).
4. **Single-issue scope** — each myrmidon operates on exactly one issue on an isolated
   feature branch.

`--dangerously-skip-permissions` **must not** be added to host-level, interactive, or
shared agent invocations without the same containerization and tool-scoping controls.

---

## Agent Coordination

The HomericIntelligence agent hierarchy for Odysseus work:

```
Nestor (research/ideation)
  └─► Agamemnon (planning + HMAS orchestration)
        └─► Myrmidon (Claude Code, one issue at a time)
```

- **Nestor** (`control/Nestor`) performs research and ideation, then hands off to
  Agamemnon with a structured brief.
- **Agamemnon** (`control/Agamemnon`) holds the planning and task coordination
  role formerly held by ai-maestro (removed per ADR-006). It dispatches myrmidons for
  implementation work.
- **Myrmidons** operate one-issue-at-a-time on isolated feature branches. Concurrent
  myrmidon sessions on the same file must not be scheduled by Agamemnon without
  coordination.

If two myrmidon sessions produce conflicting edits to the same file, the conflict
escalates to a human operator before either PR is merged.

---

## Escalation — Human Review Required

The following situations require a human operator before proceeding:

- **Editing or superseding an accepted ADR** — write a new ADR and tag a human reviewer.
- **Bumping a submodule SHA** — cross-repo integration events need explicit sign-off.
- **Any change to `.github/workflows/`** — CI pipeline changes affect all contributors.
- **Editing canonical configs** (`configs/nomad/`, `configs/nats/`) — coordinate with
  the operator responsible for each host.
- **Cross-submodule integration changes** — changes that must land atomically across
  two or more submodule repos.
- **Ambiguous or conflicting desired-state** — when the issue description, ADRs, and
  existing code give conflicting signals about the intended behavior.
- **`--dangerously-skip-permissions` outside the container** — requires explicit human
  authorization.

To escalate: post a comment on the relevant GitHub issue describing the blocker and tag
`@mvillmow` (or the on-call operator). Do not proceed with the action until unblocked.

---

## Development Guidelines

- Use `pixi run` or `just` for all task execution. Never run scripts directly.
- When adding a new submodule: `git submodule add <url> <path>`, update `.gitmodules`, and document the repo in `docs/architecture.md`.
- When writing a new ADR: use `docs/adr/template.md` as the template, use the next sequential number, and set Status to "Proposed" until merged.
- Runbooks should be written as numbered steps that can be executed top-to-bottom without prior context.
- **ai-maestro has been fully removed per ADR-006.** Agamemnon replaces its task coordination role.

---

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

---

## Common Commands

```bash
# Initialize all submodules after a fresh clone
just bootstrap

# Check status of all submodules
just status

# Apply Myrmidons declarative YAML manifests via Agamemnon API
just apply-all

# Start the NATS event bridge (Hermes)
just hermes-start

# Start the observability stack (Argus)
just argus-start

# Run a named workflow via Telemachy
just telemachy-run WORKFLOW=my-workflow

# Pull latest commits for all submodules
just update-submodules
```

---

## Verification Commands

Run these to confirm the agent behavioral contract is intact:

```bash
# AGENTS.md is present and non-empty
test -s AGENTS.md && echo "AGENTS.md present"

# AGENTS.md passes the markdownlint gate
markdownlint AGENTS.md

# All four contract elements are documented
grep -qi "Permitted"   AGENTS.md && \
grep -qi "Prohibited"  AGENTS.md && \
grep -qi "Escalation"  AGENTS.md && \
grep -q  "allowedTools\|Bash,Read,Write,Edit,Glob,Grep" AGENTS.md && \
  echo "all four contract elements present"

# Documented toolset matches the actual pipeline (no drift)
grep -q "Bash,Read,Write,Edit,Glob,Grep" e2e/claude-myrmidon.py

# AGENTS.md is discoverable from entry-point docs
grep -q "AGENTS.md" CLAUDE.md README.md docs/README.md && echo "cross-refs present"

# CI markdownlint step covers AGENTS.md
grep -q "markdownlint AGENTS.md" .github/workflows/ci.yml && echo "CI gate wired"

# Validate YAML configs and justfile
pixi run ci
```
