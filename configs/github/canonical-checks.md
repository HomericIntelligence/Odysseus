# HomericIntelligence — Canonical CI Validator Names

This catalog reserves exact GitHub Actions job names for validator categories.
A repository emits the entries that apply to its implementation; it is not
required to fabricate every catalog entry. Every emitted entry must run a
**real validator** — no echo-true placeholders.

## Authoritative validator jobs

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

Each repository retains the authoritative validators appropriate to that
repository. They are inputs to the local `required-checks-gate`; they are not
listed individually in the live ruleset.

## Sole ruleset-required check

Every first-party repository ruleset requires exactly
`required-checks-gate`, scoped to the GitHub Actions app (integration ID
`15368`) with non-strict status-check policy. The aggregate fails closed over
all authoritative validators. It must emit successfully on pull-request,
merge-group, and exact default-branch commits before the ruleset is cut over.

Repository validator lists are not interchangeable. Each `_required.yml`
defines its own aggregate dependency closure, while the cross-repository
ruleset interface remains the single stable gate name.

The authoritative repository-by-repository rollout index is the
[Odysseus #386 revision-2 activation ledger](https://github.com/HomericIntelligence/Odysseus/issues/386#issuecomment-5444607661).
Keep closure evidence on those activation issues; do not duplicate the ledger
into another manifest.

## Informational checks (report but do not block merge)

| Context name | Category | Validator |
|---|---|---|
| `docs/link-check` | Documentation | markdown-link-check |
| `ci/action-pinning` | CI hygiene | zizmor or pinact |

## Naming convention

All emitted canonical jobs MUST be defined in `.github/workflows/_required.yml`.
The ruleset status-check context is the job's explicit `name:` value.
The `_required.yml` workflow is named `Required Checks` and each job's `name:` field
is set to the canonical context string exactly (e.g. `name: lint`).

The ruleset JSON context is the bare job name `required-checks-gate`, with
`"integration_id": 15368` (GitHub Actions app) to scope the match to Actions only.

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
  status check. The load-bearing artifact is the aggregate job's exact `name:`
  field and its complete dependency closure. Renaming or removing that job
  without updating the repository ruleset breaks enforcement.
