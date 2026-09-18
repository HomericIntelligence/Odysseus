# Repository Conventions

Standards for GitHub repository metadata across the HomericIntelligence ecosystem.

## Repository Topics Convention

Every HomericIntelligence repository should include the `homeric-intelligence` topic for
discoverability, plus role-specific topics based on the component's function.

| Repo | Description | Topics |
|------|-------------|--------|
| **Odysseus** | Meta-repo and architecture hub for the HomericIntelligence distributed agent mesh | `homeric-intelligence` `meta-repo` `agent-mesh` `distributed-systems` `nats` `nomad` |
| **Agamemnon** | HMAS orchestration and task coordination (L0–L3 planning) | `homeric-intelligence` `orchestration` `agent-coordination` `rest-api` `cpp` |
| **Nestor** | C++20 research-request intake, status, and completion events | `homeric-intelligence` `research` `agent-research` `rest-api` `cpp` |
| **Keystone** | C++ in-process MessageBus and optional NATS JetStream bridge | `homeric-intelligence` `message-queue` `nats` `transport` `cpp` |
| **Hermes** | Signed inbound webhook-to-NATS bridge | `homeric-intelligence` `event-bridge` `nats` `integration` `python` |
| **Argus** | Observability: Prometheus, Loki, Grafana, Promtail | `homeric-intelligence` `observability` `prometheus` `grafana` `loki` |
| **AchaeanFleet** | OCI base and vessel images for AI-agent runtimes | `homeric-intelligence` `containers` `podman` `agent-images` |
| **Myrmidons** | GitOps manifests and agent templates; Agamemnon API reconciliation | `homeric-intelligence` `gitops` `provisioning` `yaml-manifests` |
| **Telemachy** | Declarative workflow engine over the Agamemnon REST API | `homeric-intelligence` `workflow-engine` `declarative` `python` |
| **Proteus** | CI/CD pipelines — builds AchaeanFleet images | `homeric-intelligence` `ci-cd` `dagger` `typescript` `pipelines` |
| **Athena** | Public `athena@Athena` plugin; pinned revision has 14 skill routers, with 17 IDs planned for the next reviewed release | `homeric-intelligence` `agentic` `plugins` `skills` `python` |
| **Mnemosyne** | Knowledge store/backend for Athena advise and learn | `homeric-intelligence` `knowledge-base` `memory-store` `python` |
| **Hephaestus** | Shared runtime utilities and optional automation product layer | `homeric-intelligence` `shared-utilities` `automation` `python` |
| **Scylla** | AI agent ablation benchmarking (T0–T6 tiers) | `homeric-intelligence` `benchmarking` `evaluation` `agent-testing` `python` |
| **Charybdis** | Chaos and resilience testing via Agamemnon /v1/chaos/* | `homeric-intelligence` `chaos-testing` `resilience` `testing` |
| **Odyssey** | Standalone Mojo ML training framework with no current mesh integration | `homeric-intelligence` `machine-learning` `mojo` `research` |

## Applying Topics

Repository descriptions and topics are remote metadata, not an autonomous
documentation edit. Before changing them, read the exact live values, compare
them with the intended convention, and obtain approval from the named
repository owner for the explicit repository and delta. After the approved
write, read both fields back; a successful command alone is not completion.

```bash
# Read the current values before requesting approval.
gh repo view HomericIntelligence/Agamemnon \
  --json description,repositoryTopics

# After approval, apply only the reviewed delta. Topics are added one at a time.
gh repo edit HomericIntelligence/Agamemnon \
  --description "HMAS orchestration and task coordination (L0–L3 planning)" \
  --add-topic homeric-intelligence \
  --add-topic orchestration \
  --add-topic agent-coordination \
  --add-topic rest-api \
  --add-topic cpp

# Verify the effective remote state.
gh repo view HomericIntelligence/Agamemnon \
  --json description,repositoryTopics
```

After applying, all repos with `homeric-intelligence` topic are discoverable at:
`https://github.com/search?q=topic%3Ahomeric-intelligence&type=repositories`

## Branch Naming Convention

All repos standardize on `main` as the default branch (per the ecosystem standard).
Feature branches use the pattern: `<issue-number>-<short-slug>` (e.g., `115-auto-impl`).

The historical [#24](https://github.com/HomericIntelligence/Odysseus/issues/24)
audit covered the 15 repositories that existed in 2026-06. The current
canonical inventory is 16 repositories—Odysseus plus 15 component gitlinks,
including Athena. Treat the old audit as evidence for its bound snapshot, not
as a current live-state readback.

To verify the current state of any repo:

```bash
gh repo view HomericIntelligence/<REPO> --json defaultBranchRef --jq .defaultBranchRef.name
# Expect: main
# Confirm no stale master ref:
gh api repos/HomericIntelligence/<REPO>/git/refs/heads --jq 'any(.ref=="refs/heads/master")'
# Expect: false
```

## Commit Message Convention

All repos use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): description

Body (optional)

Closes #N
```

Common types: `feat`, `fix`, `docs`, `config`, `build`, `ci`, `refactor`, `test`, `chore`

## Developer Tooling Standards

These requirements apply to **every** HomericIntelligence repository. They were
formalised as ecosystem conventions following the cross-repo audit (Odysseus
[#42](https://github.com/HomericIntelligence/Odysseus/issues/42)).

### Task Entry Points

Use each repository's checked-in task runner and dependency manifest as the
authority. Start with `just --list` where a `justfile` exists and prefer a
repository-owned recipe when it covers the operation. A maintained script may
be invoked directly when the repository documents that route or exposes no
wrapper; do not invent a recipe or convert an absent entry point into success.

Common recipe names, when implemented, are:

| Recipe | Description |
|--------|-------------|
| `default` | Lists available recipes (`@just --list`) |
| `bootstrap` | Performs repository-defined setup; inspect the recipe before use |
| `test` | Runs the full test suite |
| `lint` | Runs linters (ruff, clang-tidy, etc.) |
| `format` | Auto-formats source code |
| `build` | Builds the package or binary |

Additional repository-specific recipes are expected. Use `pixi run <task>`
when the repository's checked-in Pixi environment owns the tool. Pure-Python
repositories may instead use a checked-in uv environment. Proposed ADRs 017
and 018 are design context, not a reason to override the current repository.

**Rationale:** A discoverable task front door reduces command drift while still
allowing repository-specific environments and explicit direct-script routes.

### Dependency Manifests

Odysseus uses `pixi.toml` for its orchestration and compiled-language
toolchains. Where a repository uses Pixi, keep tools under its checked-in
dependency contract and expose task aliases only when useful:

```toml
[dependencies]
# runtime tools the justfile recipes need

[tasks]
# optional: delegate pixi tasks to just for users who prefer pixi run
test = "just test"
lint = "just lint"
```

Do not infer that every component uses Pixi. Follow its current `pyproject.toml`,
`uv.lock`, `pixi.toml`, or language-native lockfile and the commands documented
beside it.

### Python Repo Layout

There is no ecosystem-wide flat-versus-`src` layout mandate. Treat each
repository's current package paths, build backend, and import tests as the
authority. Change layout only for a repository-owned need and validate its
editable install, wheel contents, and imports in that repository.
