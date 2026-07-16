# ADR 015: Drop the `Project` Prefix Across the HomericIntelligence Ecosystem

**Status:** Accepted

---

## Context

The HomericIntelligence ecosystem currently uses a `Project` prefix on most of
its component repositories. The exceptions are the meta-repo itself
(`Odysseus`), the container image library (`AchaeanFleet`), and the worker-pool
manifest repo (`Myrmidons`); all other 11 submodules of Odysseus carry the
prefix.

The prefix is internally redundant (the org name `HomericIntelligence` already
implies a project context), it is read-incorrectly as a literal English word by
some tooling (e.g. shell tab-completion, log scanners, container registries that
alphabetise by repo name), and it makes per-repo language conventions more
opaque: `pip install project-hephaestus`, but the import namespace is already
`hephaestus`; the CMake option is `ProjectAgamemnon_BUILD_TESTING=ON` but the
binary is intended to be `Agamemnon_server`. Three names in the repo (a slug, a
PyPI distribution, a CMake option, often a binary name) encode the same concept
with three different word forms, and the only divergent one — the prefix —
exists for historical reasons (these were once component names inside the
sgsg / modern-cpp-template family of "ProjectFoo" scaffolding templates).

The refactor is an opportunity, not a mandate: there is no broken behaviour
today, only friction. The companion decision ([ADR-016](016-split-hephaestus.md))
carves out the agentic plugin/skill surface from `ProjectHephaestus` into a
new repo `Athena`, and both changes are made together so the ecosystem sees one
coordinated rename, not two half-applied ones.

## Decision

Adopt a hard cutover: drop the `Project` prefix across the entire ecosystem.
After this ADR lands, every HomericIntelligence component repo is named by its
Greek-mythology noun alone (Hephaestus, Athena, etc.), and every language-level
identifier that used the prefixed form has been re-keyed to the bare form.

| Old repo                       | New repo            | New PyPI name        | New CMake option                  | New binary           |
|--------------------------------|---------------------|----------------------|-----------------------------------|----------------------|
| ProjectArgus                   | Argus               | `argus`              | n/a (Python only)                 | n/a                  |
| ProjectHermes                  | Hermes              | `hermes`             | n/a (Python only)                 | n/a                  |
| ProjectTelemachy               | Telemachy           | `telemachy`          | n/a (Python only)                 | n/a                  |
| ProjectKeystone                | Keystone            | n/a (C++)            | `Keystone_BUILD_TESTING=ON`       | `Keystone_server`    |
| ProjectProteus                 | Proteus             | n/a (TS)             | n/a                               | n/a                  |
| ProjectOdyssey                 | Odyssey             | n/a (Mojo)           | n/a                               | n/a                  |
| ProjectScylla                  | Scylla              | `scylla`             | n/a                               | n/a                  |
| ProjectMnemosyne               | Mnemosyne           | `mnemosyne`          | n/a                               | n/a                  |
| ProjectHephaestus              | Hephaestus          | `hephaestus`         | n/a                               | n/a                  |
| ProjectAgamemnon               | Agamemnon           | n/a (C++)            | `Agamemnon_BUILD_TESTING=ON`       | `Agamemnon_server`   |
| ProjectNestor                  | Nestor              | n/a (C++)            | `Nestor_BUILD_TESTING=ON`          | `Nestor_server`      |
| ProjectCharybdis               | Charybdis           | n/a (C++)            | `Charybdis_BUILD_TESTING=ON`       | `Charybdis_server`   |
| *(NEW)* — see ADR-016          | Athena              | `athena`             | n/a                               | n/a                  |

Already unprefixed and unchanged: `Odysseus`, `AchaeanFleet`, `Myrmidons`.

The rename uses a **hard cutover** — GitHub-side repository renames are done
first (each `Project<Foo>` is renamed to `<Foo>`, GitHub auto-installs a 301
redirect from the old URL), then a single Odysseus PR updates every
consumer reference in one go. https links to the old URLs continue to resolve
through the redirect for the lifetime GitHub preserves it; new work uses the
new URLs exclusively. There is no dual-pin transitional cycle in the meta-repo
— it would double the submodule count for a release window without removing
the rename's blast radius.

Wire-protocol identifiers — NATS subject names ({ADR-013}), HMAS roles,
GitHub label names — are unchanged. They are part of the API contract, not
the name. Only naming-bound identifiers change (repo slug, PyPI distribution,
CMake option, C++ binary basename, paths, comments, docs).

> **Wire-payload note.** The `epic_key` field defined in [ADR-013](013-hmas-mesh-wire-contracts.md)
> has the shape `{repo_slug}-{issue_number}`. The `repo_slug` half absorbs the
> rename transparently: a `ProjectFoo-42` epic from yesterday and a `Foo-42`
> epic from today are the same payload key once the slug half shortens. No
> schema change to wire payloads, no per-payload migration is required — only
> the projects that *consume* an epic key need to be aware that old keys carry
> the `Project<Name>-` prefix and new keys carry the bare name.

## Consequences

**Positive:**

- One canonical name per concept. Repo, distribution, import namespace,
  binary all read the same to a human.
- The PyPI namespace collision risk that motivated the `project-` PyPI
  prefix disappears (`pip install hephaestus` reaches `HomericIntelligence/Hephaestus`,
  not the unrelated `hephaestus` first-party package if and when we ship to
  PyPI).
- The CMake options and binary basements no longer carry a `Project`
  prefix that is meaningless inside a single subproject.
- GitHub auto-redirects provide a forgiving window for any third-party doc,
  blog post, or external CI that still references the old slug.

**Negative:**

- 11 sequential GitHub-side repo renames plus 1 repo creation for Athena
  ([ADR-016](016-split-hephaestus.md)). Each rename is a human-driven action;
  the per-repo internal touch-up PRs that follow each rename are also
  human-driven (must be submitted to each submodule repo, not the
  meta-repo).
- The Odysseus PR that updates `.gitmodules`, the justfile, `docs/architecture.md`,
  and the README ecosystem CI table touches many files at once. The blast
  radius includes any user running `just bootstrap` during the cutover window
  — they will see either the old or new state, never a mix, because both ends
  of the GitHub redirect chain point at the same commit hash.
- AICH agents running in `[automation]` mode (per `hephaestus.automation` in the
  Hephaestus repo) reference `pipeline-step` identifiers that include the
  component slug; those references need a one-shot migration script in the
  Hephaestus repo. Out of scope for Odysseus; out of scope for this ADR; the
  Hephaestus repo owns that migration.
- Any local clone of an old-slug submodule will need a re-add with the new
  URL after the rename. git itself handles this gracefully (submodule paths
  are local, URLs come from `.gitmodules`), but operators with cached
  checkouts should re-run `just bootstrap`.

**Neutral:**

- The `scripts/check-submodule-drift.sh` and `scripts/ecosystem-health.sh`
  scripts derive the per-repo name list from `.gitmodules` itself, so they pick
  up the rename automatically without code edits.
- CodeQL/Python-specific supply-chain tooling that keys off the repo name will
  follow GitHub's redirect — no manual intervention.

## References

- [ADR 016](016-split-hephaestus.md) - Companion decision: split
  `ProjectHephaestus` into `Hephaestus` + `Athena`. Made in the same release.
- [ADR 013](013-hmas-mesh-wire-contracts.md) - Wire protocol whose subject names
  are intentionally NOT touched by this ADR.
- [ADR 006](006-decouple-from-ai-maestro.md) - Precedent for a cross-repo
  reorganisation in a single coordinated cutover (the ai-maestro removal).
- `docs/runbooks/rename-and-split.md` - The per-submodule migration runbook
  this ADR points to.
