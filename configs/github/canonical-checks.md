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

This means each context in the org ruleset resolves to:
`Required Checks / lint`, `Required Checks / unit-tests`, etc.

**Wait** — this means the required_status_checks contexts in org-ruleset.json must be
updated to include the workflow prefix. Check the GitHub docs: org ruleset
`required_status_checks` entries use the full check name as GitHub reports it, which
for Actions is `<workflow name> / <job name>`.

Actually, re-check: for GitHub rulesets (not classic branch protection), the
`required_status_checks` `context` field matches the check name exactly as it appears
in the PR checks list. For GitHub Actions, that is `<workflow-name> / <job-name>` when
the job has a `name:` field, or just `<job-id>` when it doesn't. So if the workflow
`name:` is `Required Checks` and the job `name:` is `lint`, the context is
`Required Checks / lint`.

The `org-ruleset.json` contexts above assume the job names are used directly as contexts.
If the workflow adds a prefix, update the JSON accordingly. Verify by opening one test PR
after the first `_required.yml` lands and reading `gh pr checks` output to see the exact
strings GitHub reports.

For now, write the JSON with bare names (`lint`, `unit-tests`, etc.) as placeholders.
After Wave 1 PRs merge and a test PR is opened, the exact context strings will be
confirmed and the JSON updated if needed before the ruleset is applied in Phase 3.
