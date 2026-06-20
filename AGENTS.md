# AGENTS.md — Odysseus

> **AI agents:** This file defines the behavioral contract for AI agents operating in
> this repository. Read this before taking any action. For architecture context, see
> [CLAUDE.md](CLAUDE.md).

## Audience

This document governs the following AI agent runtimes operating in Odysseus:

- **Claude Code myrmidons** — Claude CLI instances launched by `e2e/claude-myrmidon.py`
  inside the `achaean-claude` container
- **Agamemnon planner** — the HMAS planning/orchestration agent (`control/ProjectAgamemnon`)
- **Nestor researcher** — the research and ideation agent (`control/ProjectNestor`)

Human contributors: see [CLAUDE.md](CLAUDE.md) for development guidelines.

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
| `scripts/` | Yes | Yes | Validation and utility scripts |
| `justfile` | Yes | Yes | Task execution entry points |
| `pixi.toml` | Yes | Coordinate | Dependency manifest — coordinate before editing |
| `.github/workflows/` | Yes | **No** | Requires human review before any edit |
| `.gitmodules` | Yes | **No** | Submodule pins require integration sign-off |
| Submodule working trees | Yes | **No** | Changes belong in each submodule's own repo |
| Any file at repo root | Yes | Yes | README, CLAUDE.md, AGENTS.md, etc. |

### Out of scope — agents must not touch

- **Accepted ADRs** (`docs/adr/00*.md` with `Status: Accepted`) — append-only invariant
  per CLAUDE.md principle 3. Write a new superseding ADR instead.
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
- `just <recipe>`, `pixi run <task>` — task execution (CLAUDE.md mandates these over
  direct script invocation)
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
  ProjectAgamemnon is the replacement.
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

- **Nestor** (`control/ProjectNestor`) performs research and ideation, then hands off to
  Agamemnon with a structured brief.
- **Agamemnon** (`control/ProjectAgamemnon`) holds the planning and task coordination
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
