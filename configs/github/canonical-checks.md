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
