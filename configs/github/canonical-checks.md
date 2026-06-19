# HomericIntelligence — Canonical Required CI Check Names

All 15 repos must emit these exact GitHub Actions status check names.
Each check must run a **real validator** — no echo-true placeholders.

## Required checks (block merge if failing)

| Context name | Category | Validator examples |
|---|---|---|
| `lint` | Linting | pre-commit, ruff, shellcheck, yamllint, clang-format, mypy, pyright, clang-tidy |
| `unit-tests` | Testing | pytest, ctest, mojo test, bats |
| `integration-tests` | Testing | network integration run; schema-validation for no-network repos |
| `security/dependency-scan` | Security | pip-audit, conan audit, trivy fs, npm audit |
| `security/secrets-scan` | Security | gitleaks |
| `build` | Build | pixi run build, cmake --build, docker build |
| `schema-validation` | Validation | check-jsonschema against workflow YAMLs / pixi.toml / NATS schemas |
| `deps/version-sync` | Validation | verify VERSION/pyproject.toml/pixi.toml/Conanfile parity |

## Informational checks (report but do not block merge)

| Context name | Category | Validator |
|---|---|---|
| `docs/link-check` | Documentation | markdown-link-check |
| `ci/action-pinning` | CI hygiene | zizmor or pinact |

## Naming convention

All canonical jobs MUST be defined in `.github/workflows/_required.yml` in each repo.
The GitHub status check name is `<workflow.name> / <job.name>`.
The `_required.yml` workflow is named `Required Checks` and each job's `name:` field
is set to the canonical context string exactly (e.g. `name: lint`).

The ruleset JSON context strings are **bare job names** (e.g. `lint`, `unit-tests`),
with `"integration_id": 15368` (GitHub Actions app) to scope the match to Actions only.

**Verified** (2026-04-26): GitHub reports check names as bare job `name:` values when
the job has an explicit `name:` field — the workflow name prefix does NOT appear in
the context string. `repo-ruleset.json` and `repo-ruleset-active.json` use bare names
with `integration_id: 15368`.

### Why the filename is `_required.yml`

The leading underscore is a deliberate fleet convention, not an opaque choice —
and the filename is organizational, not load-bearing:

- **Sorts first / signals intent.** The underscore sorts ahead of letters, so the
  required-checks workflow appears at the top of `.github/workflows/` and the
  Actions tab — visually marking "this is the gate that blocks merges."
- **Uniform across all repos.** Every HomericIntelligence repo uses this exact
  path, so `tools/github/apply-repo-rulesets.sh` and
  `docs/runbooks/branch-protection-rollout.md` can reference one filename
  fleet-wide.
- **The filename is NOT the enforcement contract.** Renaming the file would only
  require updating doc/tooling references; it would not change any required
  status check. The load-bearing artifact is each job's `name:` field — GitHub
  derives the status-check context from it. Renaming or removing a *job* without
  updating the ruleset contexts (and re-applying the ruleset) is what breaks
  enforcement. Note the two ruleset forms in this repo:
  `org-ruleset*.json` pin `"Required Checks / <job>"`, while `repo-ruleset*.json`
  pin the bare `"<job>"` with `integration_id: 15368`. Treat the job names — not
  the filename — as the API.
