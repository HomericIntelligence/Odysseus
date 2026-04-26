# HomericIntelligence — Canonical Required CI Check Names

All 15 repos must emit these exact GitHub Actions status check names.
Each check must run a **real validator** — no echo-true placeholders.

## Required checks (block merge if failing)

| Context name | Category | Validator examples |
|---|---|---|
| `lint` | Linting | pre-commit, ruff, shellcheck, yamllint, clang-format |
| `unit-tests` | Testing | pytest, ctest, mojo test, bats |
| `integration-tests` | Testing | network integration run; schema-validation for no-network repos |
| `security/dependency-scan` | Security | pip-audit, conan audit, trivy fs, npm audit |
| `security/secrets-scan` | Security | gitleaks |
| `build` | Build | pixi run build, cmake --build, docker build |
| `typecheck` | Linting | mypy, pyright, clang-tidy |
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

This means each context in the ruleset JSON is the workflow-prefixed string:
`Required Checks / lint`, `Required Checks / unit-tests`, etc.

**Verified** (2026-04-26): `repo-ruleset.json` and `repo-ruleset-active.json` use the
prefixed form `Required Checks / <job>`. This was confirmed by inspecting the active
`homeric-main-baseline` rulesets on all 15 repos via `gh api repos/.../ rulesets/<id>`.
Keystone's ruleset was the only divergence (bare names, 13 contexts); it is being
normalized to the canonical 9 prefixed contexts in PR #482.
