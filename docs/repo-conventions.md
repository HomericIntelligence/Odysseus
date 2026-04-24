# Repository Conventions

Standards for GitHub repository metadata across the HomericIntelligence ecosystem.

## Repository Topics Convention

Every HomericIntelligence repository should include the `homeric-intelligence` topic for
discoverability, plus role-specific topics based on the component's function.

| Repo | Description | Topics |
|------|-------------|--------|
| **Odysseus** | Meta-repo and architecture hub for the HomericIntelligence distributed agent mesh | `homeric-intelligence` `meta-repo` `agent-mesh` `distributed-systems` `nats` `nomad` |
| **ProjectAgamemnon** | HMAS orchestration and task coordination (L0–L3 planning) | `homeric-intelligence` `orchestration` `agent-coordination` `rest-api` `cpp` |
| **ProjectNestor** | Research, ideation, and handoff to Agamemnon | `homeric-intelligence` `research` `agent-research` `rest-api` `cpp` |
| **ProjectKeystone** | Invisible transport layer — BlazingMQ intra-host, NATS JetStream cross-host | `homeric-intelligence` `message-queue` `nats` `blazingmq` `transport` `cpp` |
| **ProjectHermes** | External message delivery bridge to/from NATS | `homeric-intelligence` `event-bridge` `nats` `integration` `python` |
| **ProjectArgus** | Observability: Prometheus, Loki, Grafana, Promtail | `homeric-intelligence` `observability` `prometheus` `grafana` `loki` |
| **AchaeanFleet** | Container image library for all agents and services | `homeric-intelligence` `containers` `podman` `agent-images` |
| **Myrmidons** | GitOps manifests and agent templates; Agamemnon API reconciliation | `homeric-intelligence` `gitops` `provisioning` `yaml-manifests` |
| **ProjectTelemachy** | Declarative workflow engine for Agamemnon/Nestor | `homeric-intelligence` `workflow-engine` `declarative` `python` |
| **ProjectProteus** | CI/CD pipelines — builds AchaeanFleet images | `homeric-intelligence` `ci-cd` `dagger` `typescript` `pipelines` |
| **ProjectMnemosyne** | Skills marketplace — memory store for advise/learn plugins | `homeric-intelligence` `skills-registry` `memory-store` `python` |
| **ProjectHephaestus** | Shared utilities, Claude Code plugins, skills | `homeric-intelligence` `shared-utilities` `claude-code` `plugins` `python` |
| **ProjectScylla** | AI agent ablation benchmarking (T0–T6 tiers) | `homeric-intelligence` `benchmarking` `evaluation` `agent-testing` `python` |
| **ProjectCharybdis** | Chaos and resilience testing via Agamemnon /v1/chaos/* | `homeric-intelligence` `chaos-testing` `resilience` `testing` |
| **ProjectOdyssey** | Mojo ML research sandbox; stable work graduates to AchaeanFleet | `homeric-intelligence` `machine-learning` `mojo` `research` |

## Applying Topics

Use `gh repo edit` to apply topics to each repo. Topics must be set one at a time with `--add-topic`.

```bash
# Example: apply topics to ProjectAgamemnon
gh repo edit HomericIntelligence/ProjectAgamemnon \
  --description "HMAS orchestration and task coordination (L0–L3 planning)" \
  --add-topic homeric-intelligence \
  --add-topic orchestration \
  --add-topic agent-coordination \
  --add-topic rest-api \
  --add-topic cpp
```

After applying, all repos with `homeric-intelligence` topic are discoverable at:
`https://github.com/search?q=topic%3Ahomeric-intelligence&type=repositories`

## Branch Naming Convention

All repos standardize on `main` as the default branch (per the ecosystem standard).
Feature branches use the pattern: `<issue-number>-<short-slug>` (e.g., `115-auto-impl`).

## Commit Message Convention

All repos use [Conventional Commits](https://www.conventionalcommits.org/):
```
type(scope): description

Body (optional)

Closes #N
```

Common types: `feat`, `fix`, `docs`, `config`, `build`, `ci`, `refactor`, `test`, `chore`
