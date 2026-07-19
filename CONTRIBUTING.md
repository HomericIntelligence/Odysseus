# Contributing to Odysseus

Thank you for your interest in contributing to Odysseus! This is the meta-repo and unified
architecture hub for the HomericIntelligence distributed agent mesh. Odysseus itself contains
no application code -- its value is coordination: Architecture Decision Records, operational
runbooks, shared infrastructure configs, and submodule references for every component in the
ecosystem.

## Quick Links

- [Development Setup](#development-setup)
- [What You Can Contribute](#what-you-can-contribute)
- [Development Workflow](#development-workflow)
- [Pull Request Process](#pull-request-process)
- [Code Review](#code-review)
- [Getting Help](#questions)

## Development Setup

### Prerequisites

- [Git](https://git-scm.com/) (with submodule support)
- [GitHub CLI](https://cli.github.com/) (`gh`) for PR workflows
- [Pixi](https://pixi.sh/) for environment management
- [Just](https://just.systems/) as the command runner

### Environment Setup

```bash
# Clone with all submodules
git clone --recursive https://github.com/HomericIntelligence/Odysseus.git
cd Odysseus

# Activate the Pixi environment
pixi shell

# Bootstrap all submodules and verify the setup
just bootstrap
```

### Verify Your Setup

```bash
# Check that Just is available and list all recipes
just --list

# Verify GitHub CLI authentication
gh auth status

# Check submodule status
just status
```

## What You Can Contribute

Odysseus is a meta-repo. Contributions fall into these categories:

### Documentation

- **Architecture Decision Records (ADRs)** -- Propose new architectural decisions in
  `docs/adr/`. Copy the format from an existing ADR, use the next sequential number,
  and set Status to "Proposed" until merged. ADRs are append-only: once accepted, they
  are never edited. Superseding decisions get a new ADR that references the old one.

- **Runbooks** -- Add operational procedures in `docs/runbooks/`. Runbooks should be
  written as numbered steps that can be executed top-to-bottom without prior context.

- **Architecture updates** -- Keep `docs/architecture.md` current as the system evolves.
  This is the canonical component map for the entire ecosystem.

### Configuration Files

- **NATS configs** -- Server and leaf node configurations in `configs/nats/`. These are
  the authoritative source; individual hosts copy or symlink from here.

- **Nomad configs** -- Client and server configurations in `configs/nomad/`. Same
  canonical-source principle as NATS.

### Justfile Recipes

Add new cross-repo commands to the `justfile`. Recipes should be self-documenting and
follow the existing naming conventions. Run `just --list` to see current recipes.

### Submodule Management

- **Adding a submodule**: `git submodule add <url> <path>`, update `.gitmodules`, and
  document the repo in `docs/architecture.md`.

- **Updating pins**: The submodule SHAs in this repo represent the last known-good
  cross-repo integration point. Update pins deliberately, not casually.

### Docker Compose and E2E Tests

- Compose files for local development and E2E testing live in the `e2e/` directory.
- Topology definitions and test harnesses support multi-container integration scenarios.

### CI Workflows

- GitHub Actions workflows in `.github/workflows/` automate validation, testing, and
  deployment across the ecosystem.

## Development Workflow

### 1. Find or Create an Issue

Before starting work:

- Browse [existing issues](https://github.com/HomericIntelligence/Odysseus/issues)
- Comment on an issue to claim it before starting work
- Create a new issue if one doesn't exist for your contribution
- Wait for maintainer approval on significant changes

### 2. Branch Naming Convention

Create a feature branch from `main`:

```bash
# Update your local main branch
git checkout main
git pull origin main

# Create a feature branch
git checkout -b <issue-number>-<short-description>

# Examples:
git checkout -b 42-add-nats-auth-config
git checkout -b 15-update-disaster-recovery-runbook
```

**Branch naming rules:**

- Start with the issue number
- Use lowercase letters
- Use hyphens to separate words
- Keep descriptions short but descriptive

### 3. Make Your Changes

- Follow the contribution guidelines for the category your change falls into
- Keep commits focused and atomic
- Update documentation as needed

### 4. Commit Message Format

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**

| Type       | Description                |
|------------|----------------------------|
| `feat`     | New feature                |
| `fix`      | Bug fix                    |
| `docs`     | Documentation only         |
| `style`    | Formatting, no code change |
| `refactor` | Code restructuring         |
| `test`     | Adding/updating tests      |
| `chore`    | Maintenance tasks          |

**Example:**

```bash
git commit -m "docs(adr): add ADR-007 for container registry migration

Proposes migrating container images from Docker Hub to GHCR for
tighter GitHub Actions integration and free private image hosting.

Closes #55"
```

### 5. Push and Create Pull Request

```bash
# Push your branch
git push -u origin <branch-name>

# Create pull request linked to issue
gh pr create --title "[Type] Brief description" --body "Closes #<issue-number>"
```

### Never Push Directly to Main

The `main` branch is protected. All changes must go through pull requests:

- Direct pushes to `main` will be rejected
- Even single-line fixes require a PR
- This ensures code review and CI validation

## Markdown Standards

All documentation files must follow these standards:

- Code blocks must have a language tag (`toml`, `bash`, `hcl`, `yaml`, `text`, etc.)
- Code blocks must be surrounded by blank lines (before and after)
- Lists must be surrounded by blank lines
- Headings must be surrounded by blank lines
- Use relative links when referencing files within the repository

## Pull Request Process

### Before You Start

1. Ensure an issue exists for your work (create one if needed)
2. Create a branch from `main` using naming convention: `<issue-number>-<description>`
3. Implement your changes
4. Verify locally: `just --list` to confirm justfile syntax, review docs for correctness

### Creating Your Pull Request

```bash
# Push your branch
git push -u origin <branch-name>

# Create pull request linked to issue
gh pr create --title "[Type] Description" --body "Closes #<issue-number>"
```

**PR Requirements:**

- PR must be linked to a GitHub issue
- PR title should be clear and descriptive
- PR description should summarize changes and reference the issue

## Code Review

### What Reviewers Look For

Reviews focus on:

- **Correctness** - Are configurations valid and will they work as expected?
- **Completeness** - Are ADRs properly formatted? Do runbooks have all steps?
- **Consistency** - Do changes follow existing patterns and conventions?
- **Security** - Do configs avoid exposing secrets, open ports, or weak auth?
- **Documentation** - Is `docs/architecture.md` updated if structure changed?

### Responding to Review Comments

Address review comments promptly:

- Keep responses short (1 line preferred)
- Start with "Fixed -" to indicate resolution
- Examples:
  - `Fixed - Updated server.conf to bind monitoring to localhost`
  - `Fixed - Added missing step 4 to runbook`

### After Review

1. Make requested changes
2. Push changes to update the PR
3. Request re-review if needed

## Branch Protection Policy

The `main` branch is protected by a live GitHub repository ruleset. The complete
live ruleset is authoritative. `configs/github/repo-ruleset*.json` records the
reviewed Odysseus input parameters but is not a fleet-wide replacement payload;
see `docs/runbooks/branch-protection-rollout.md` for read-back and staged
activation.

### Protection Rules

- **Direct pushes blocked** - All changes to `main` must go through pull requests (`deletion` and non-PR pushes are rejected).
- **Checks-only merge gate** - The live repository ruleset requires 0 approvals; required checks and resolved review threads remain mandatory.
- **Review threads must be resolved** - All PR review conversations must be resolved before merge (`required_review_thread_resolution`).
- **Signed commits required** - Commits on `main` must be signed (`required_signatures`).
- **CI status checks must pass** - The 11 live contexts are `lint`, `unit-tests`, `integration-tests`, `security/dependency-scan`, `security/secrets-scan`, `build`, `schema-validation`, `deps/version-sync`, `test`, `install`, and `release`.
- **Current merge metadata** - GitHub currently reports `allow_merge_commit: true`, `allow_squash_merge: true`, and `allow_rebase_merge: false`. This rollout configures the merge queue itself to use `SQUASH`.
- **Merge queue is staged** - Workflow readiness lands first. A human-reviewed, post-merge operator step dry-runs the live-derived payload, activates one pilot, and records a queued smoke result before any fleet rollout.

### Merge Convention

Always use the following command to merge your PR:

```bash
gh pr merge --auto --squash
```

This enables auto-merge using squash. After queue activation, GitHub enqueues the
PR once its entry conditions are met and retests the synthetic merge group
against the current `main` tip.

### For Repo Admins

Use the repository-owned policy process and
`docs/runbooks/branch-protection-rollout.md`. Do not create a live baseline from
the generic Odysseus JSON, activate a queue before its workflows reach `main`,
or skip independent human review of workflow changes.

## Key References

- **Available recipes**: Run `just --list` to see all cross-repo commands
- **ADR format**: See existing ADRs in `docs/adr/` for the template
- **Runbook format**: See existing runbooks in `docs/runbooks/` for the template
- **Component map**: See `docs/architecture.md` for the full system overview
- **Project overview**: See `AGENTS.md` for repository structure and principles

## Reporting Issues

### Bug Reports

Include:

- Clear title describing the issue
- Steps to reproduce the problem
- Expected vs actual behavior
- Relevant configuration snippets or logs

### Feature Requests

Include:

- Clear title describing the feature
- Problem it solves or value it provides
- Proposed solution (if you have one)
- Alternatives considered

### Security Issues

**Do not open public issues for security vulnerabilities.**

See [SECURITY.md](SECURITY.md) for the responsible disclosure process.

## Questions

If you have questions:

1. Check existing documentation in [AGENTS.md](AGENTS.md) and [docs/architecture.md](docs/architecture.md)
2. Search existing GitHub issues
3. Create a new discussion or issue with your question

## Code of Conduct

Please review our [Code of Conduct](CODE_OF_CONDUCT.md) before contributing. We are committed
to providing a welcoming and inclusive environment for all contributors.

---

Thank you for contributing to Odysseus! Your effort helps keep the HomericIntelligence
ecosystem well-coordinated and documented.
