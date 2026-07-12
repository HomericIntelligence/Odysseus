# Runbook: Rename + Split (ADR-015 + ADR-016)

**Audience:** HomericIntelligence operators carrying out the cross-repo
refactor. The previous runbooks ship changes single-submodule at a time; this
one is intentionally a multi-repo refactor and is read top-to-bottom by a
single operator (typically `@mvillmow`).

**Outcome:** every `Project<Foo>` repo is renamed to `<Foo>` everywhere it
appears in the ecosystem, `ProjectHephaestus` is split into
`Hephaestus` (library) + `Athena` (plugins/skills), and the Odysseus
meta-repo either points at the new state on the same day (hard cutover) or
rolls forward in an ordered sequence (soft cutover).

> **Read first**: [ADR-015](../adr/015-drop-project-prefix.md) and
> [ADR-016](../adr/016-split-hephaestus.md) — this runbook is the
> mechanical execution of those decisions.

> **Current Execution Status (commit `0a6fb6f`, 2026-07-12):**
>
> - ✅ **Step 1 + 1b:** `Hephaestus` split → `shared/Hephaestus` +
>   `agentic/Athena` carve-out complete. Both gitlink pins already
>   updated in `.gitmodules`. The `scripts/install/60-claude-tooling.sh
>   --install` flow registers ONLY `athena@Athena`; the canonical
>   post-install template (`.claude/settings.json`) was aligned with
>   that in commit `0a6fb6f`.
> - ⏳ **Steps 2–12:** Ten upstream `HomericIntelligence/Project<X>`
>   renames remaining. Each requires (a) a GitHub web UI rename, (b) a
>   per-repo internal-touch PR (CMake options, pyproject.toml name
>   changes, internal doc references), (c) wait for merge. Order
>   matters: least-coupled first (ProjectScylla, ProjectCharybdis),
>   `ProjectAgamemnon` LAST (HMAS orchestrator with the largest blast
>   radius).
> - ⏳ **Step 13:** Odysseus-side finish. Blocked until 2–12 are green.
>   Operator workflow:
>     1. Confirm upstream stability: `git ls-remote
>        https://github.com/HomericIntelligence/<X>.git` for each renamed
>        repo.
>     2. Pre-stage on a feature branch.
>     3. `tools/apply-odysseus-rename.sh --check` (no writes; reports
>        stale `Project<X>` refs in scope files).
>     4. `tools/apply-odysseus-rename.sh --apply` (mass rewrite of
>        `.gitmodules`, `justfile`, `docker-compose.e2e.yml`,
>        `tools/github/*.sh`).
>     5. `just ecosystem-table` to regenerate the README
>        `<!-- ECOSYSTEM-CI-TABLE:START -->` block.
>     6. Open the meta-repo finish PR per section 4 — `@mvillmow` merges
>        by hand (NOT auto-merge; AGENTS.md forbids auto-merge for
>        cross-repo integration PRs).

> **Submodule pin audit (commit `07fd153`, 2026-07-12):**
>
> - The `chore(submodules): bump all 15 pins to latest upstream main` commit on
>   `chore/split-hephaestus-athena` verified **no SHA movement**: all 15
>   submodule gitlinks in `0bfe3dc` already tracked upstream-tracking SHAs and
>   remained unchanged through the bump. The meta-repo's pins are therefore
>   already current per the operator's "more recent pin" intent; an explicit
>   SHA-reset is unnecessary until upstream repos move following `Project<X>`
>   renames on GitHub.
> - `shared/Hephaestus` was uninitialized (`-`-prefixed in `git submodule
>   status`) at this branch's start; the bump cycle populated its working
>   tree to recorded SHA `5a70ad2`. This is the only material submodule
>   state change in this branch.
> - The corruption cascade (commit `0651c1c`) committed `<<<<<<<` markers as
>   file content into PR #385 and was followed by 4 fixup commits
>   (`7332fc5`, `4de6377`) plus a workflow-hardening commit (`0dd44f8`,
>   `07fd153`). See `AGENTS.md` for the regression-prevention script
>   (`scripts/git/safe-merge.sh`) and hook (`forbid-merge-conflict-markers`).
> - `tools/apply-odysseus-rename.sh --check` still reports 79 stale `Project<X>`
>   refs across `.gitmodules` (33), `docker-compose.e2e.yml` (3),
>   `docs/architecture.md` (30), `CLAUDE.md` (13). Stays the same baseline
>   for rename-side step 13.

---

## 0. Pre-flight

1. **Confirm GitHub-side redirects behave as expected.** Pick one repo as a
   probe — `ProjectHephaestus` is recommended because of its size —
   rename it on GitHub, then `git ls-remote https://github.com/HomericIntelligence/ProjectHephaestus`
   to confirm the redirect still points at the same commit hash post-rename.
   Rename via the GitHub web UI (Settings → Danger Zone → Rename) — `gh`
   does not yet have a `repo rename` subcommand.
2. **Confirm `pip install <new-name>` won't collide.** `hephaestus`, `argus`,
   `hermes`, `telemachy`, `mnemosyne`, `athena`, `scylla` are first-party
   PyPI names we'd want to own. PyPI removed XMLRPC search support in 2021
   and `pip search` returns an empty stub; use the canonical JSON API:
   `curl -s https://pypi.org/pypi/<name>/json | jq -r '.info.name + " " + (.info.version // "absent")'`.
   If any name is already taken by an unrelated project, decide whether to
   claim under `<name>-hi` (mirroring the current `project-hephaestus`
   workaround) and document the choice in the ADR-015 PR description.
3. **Confirm C++ naming convention in CMake.** Inspect
   `ProjectKeystone/CMakeLists.txt`, `ProjectAgamemnon/CMakeLists.txt`,
   `ProjectNestor/CMakeLists.txt`, `ProjectCharybdis/CMakeLists.txt` — both
   the project declaration (`project(ProjectFoo CXX)`) and the option name
   (`option(ProjectFoo_BUILD_TESTING ...)`) need to drop the `Project`
   prefix. The matching install target (`ProjectFoo_server`) follows. If a
   repo uses `add_executable(ProjectFoo_server ...)`, both the source
   definition and any `set_target_properties` need updating.
4. **Snapshot the meta-repo** with `git tag pre-rename-and-split` on
   Odysseus main, so a rollback is one `git reset` away.

## 1. The rename order — by ascending risk

The work is sequenced by how painful a half-applied state is. A repo with
few downstream consumers lands first; the wider blast-radius repos land
last.

| Step | Repo                              | Why this slot                                                          |
|------|-----------------------------------|------------------------------------------------------------------------|
| 1    | ProjectHephaestus → Hephaestus    | ADR-016 also carves Athena out; finish it in this same window.         |
| 1b   | Create `Athena` repo (new)       | Same window as step 1; carve-out from Hephaestus.                     |
| 2    | ProjectMnemosyne → Mnemosyne      | Skills marketplace; small, single-language, internal-only.             |
| 3    | ProjectTelemachy → Telemachy      | Python FastAPI; internal-only Python package.                          |
| 4    | ProjectHermes → Hermes            | Python FastAPI; small blast radius.                                    |
| 5    | ProjectArgus → Argus              | Internal observability; touches many dashboard paths in subdirs.       |
| 6    | ProjectScylla → Scylla            | Used by telemetry; small internal surface.                             |
| 7    | ProjectOdyssey → Odyssey          | Standalone Mojo; not integrated with the mesh, low coupling.           |
| 8    | ProjectProteus → Proteus          | Reads submodules' CI state; small internal blast radius.               |
| 9    | ProjectCharybdis → Charybdis      | Used by Agamemnon chaos endpoints; named in `controls/`.               |
| 10   | ProjectKeystone → Keystone        | Transport-layer, references in many submodules.                        |
| 11   | ProjectNestor → Nestor            | Internal C++, downstream dispatch uses slug.                           |
| 12   | ProjectAgamemnon → Agamemnon      | Largest blast radius (HMAS orchestrator). Last so its SHA is current.  |

Each step is one GitHub-side rename plus one per-submodule internal-touch PR.
The Odysseus-side finish (step 13, below) is the single coordinated PR after
all 12 plus the Athena creation are in. Hard cutover means each repo can be
paired with its internal-touch PR in any order — the consumer (Odysseus)
points at the new SHA only at step 13.

## 2. Per-repo internal touch-up PR

For each renamed repo, the operator opens a single PR against the renamed
repo's `main` branch that updates internal references to drop the prefix.
**The PR is reviewed and merged in the renamed repo, not in Odysseus** —
per AGENTS.md, submodule working trees do not get edited from the meta-repo.

```text
title: chore: drop the 'Project' prefix internally (@ADR-015)
body:
  Closes #<tracking-issue>

  This repo was renamed from Project<X> to <X>. This PR updates internal
  references to drop the prefix:

  - <list the touched files in this repo>
  - CMake options/macros/binaries (C++ repos only)
  - PyPI distribution name in pyproject.toml (Python repos only)
  - Internal docs (README.md, ARCHITECTURE.md, etc.)

  Behavior is unchanged. The repo's CI must remain green.
```

Common touch surface per language:

### Python repos (Hephaestus, Mnemosyne, Hermes, Telemachy, Scylla, Argus)

Files typically touched:

- `pyproject.toml` — `name = "project-<x>"` → `name = "<x>"`.
- `pixi.toml` — `name = "project-<x>"` → `name = "<x>"`.
- Any `setup.cfg`, `setup.py`, or hatch hook that re-states the name.
- Internal docstring references in `*.md`, `*.rst`.
- The dock `hephaestus-` distribution, if used as a CLI entry-point name,
  becomes `<x>-`. (Check `project.scripts` in `pyproject.toml`.)
- README links to the repo's own GitHub URL.

### C++ repos (Keystone, Agamemnon, Nestor, Charybdis)

Files typically touched:

- `CMakeLists.txt` — `project(Project<X> CXX)` → `project(<X> CXX)`,
  `option(Project<X>_BUILD_TESTING ...)` → `option(<X>_BUILD_TESTING ...)`,
  `add_executable(Project<X>_server ...)` → `add_executable(<X>_server ...)`,
  any `set_target_properties(Project<X>_<foo> ...)` argument.
- `conan/CMakeLists.txt` or install scripts that name the target.
- `.github/workflows/*.yml` — `name:` and any `${{ github.event.repository.name }}`
  references that bake the slug into env.
- README/ARCHITECTURE MD.

### Mojo repos (Odyssey)

- README/ARCHITECTURE MD and any examples that pin to a particular
  directory path with `ProjectOdyssey`.
- Pixi/npm packaging names.

### TS repos (Proteus)

- `package.json` `name` field.
- README/ARCHITECTURE MD.

## 3. The Hephaestus + Athena carve-out (step 1 + 1b)

This is the only step that creates a new repo and rebalances an existing one.
Run as a coordinated pair of PRs.

### 3a Hephaestus repo (renamed, with surface removed)

PR title: `chore(hephaestus): drop plugin/skill surface (moved to Athena)`

In the `ProjectHephaestus` working tree, drop these trees:

- `.claude-plugin/`
- `.codex-plugin/`
- `.agents/`
- `plugins/`
- `skills/` (LLM-targeted skills only — recheck: skills that import
  `hephaestus.*` go to Athena; pure-data skill indexes stay here)
- `assets/` (insofar as it served the skills; otherwise stays)

Keep:

- `hephaestus/` Python source tree, including `hephaestus.automation`.
- `tests/`, `scripts/`, `docs/`.
- All top-level packaging (`pyproject.toml`, `pixi.toml`, `justfile`).
- `AGENTS.md`, `README.md`, `COMPATIBILITY.md`, `NOTICE`, `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `LICENSE`.

Touch (do not preserve verbatim):

- **`CLAUDE.md`** — the existing document articulates the library/product
  split that this ADR makes physical. After the carve-out it must be
  revised in-place to describe Hephaestus as the *library-only* repo:
  - The "Role in Ecosystem" prose that lists Hephaestus's sister repos
    keeps the same names; delete the \"Skill Catalog\" table that
    enumerates `hephaestus:<skill>` plugins (skills moved to Athena).
  - The `Skill(skill: "hephaestus:skill-advisor", ...)` automatic-skill-selection
    section deletes the same table; document that the host-side
    selection now lives in Athena's `~/.claude/settings.json` block.
  - The "Library vs product layer" section stays (Hephaestus still
    owns the boundary) but the prose clarifies that the *product*
    surface is the Python `hephaestus.automation` orchestrator, no
    longer the plugin/skill tree.
  - Any example commands that `cd`-into the now-carved paths
    (`skills/`, `plugins/`, `.claude-plugin/`) remove those paths and
    reference Athena's README instead.

Update Hephaestus's `pyproject.toml` to declare:

```toml
[project.optional-dependencies]
# Existing "automation" extra — unchanged.
automation = [...]
```

The Python package name in `pyproject.toml` becomes `hephaestus` (drop "project-"
per ADR-015). Internal references that look like `from hephaestus.automation
import ...` need no change.

### 3b Athena repo (new)

In a fresh empty repo `Athena`, copy the carved-out surface from step 3a:

- `.claude-plugin/plugin.json` — Claude Code plugin manifest.
- `.codex-plugin/plugin.json` — Codex plugin manifest.
- `.agents/` — agent definitions.
- `plugins/` — host-specific plugin code.
- `skills/` — LLM-facing skills (`advise/`, `brainstorm/`, `code-review/`,
  `repo-analyze/`, etc.).
- `assets/` — supporting data the skills need at install time.

Add to `Athena/pyproject.toml`:

```toml
[project]
name = "athena"

dependencies = [
  "hephaestus",                       # Library the skills import from.
]
[project.optional-dependencies]
automation = ["hephaestus[automation]"]   # Used by skill code that needs the orchestrator.
```

Install contract (the user-facing surface): `pip install athena` works for
the Python-side pieces (HePHAESTUS library dep), and a host-specific plugin
install path (per-host directive) wires up `.claude-plugin/`, `.codex-plugin/`,
or `.agents/` into Claude Code / Codex / Pi. The minimum-viable install for
all three hosts is:

- **Claude Code**: clone Athena, set `"athena@Athena": true` in
  `~/.claude/settings.json`. Same shape as today's `hephaestus@ProjectHephaestus`,
  just with the new slug.
- **Codex**: drop `.codex-plugin/` into Codex's plugin directory per its
  documented install mechanism. Document the exact path in Athena's
  README.
- **Pi**: drop `.agents/` into Pi's agent directory per its
  documented install mechanism.

For Odysseus's own `.claude/settings.json`, the entry becomes:

```diff
 {
   "enabledPlugins": {
-    "hephaestus@ProjectHephaestus": true
+    "hephaestus@Hephaestus": true,
+    "athena@Athena": true
   }
 }
```

## 4. Odysseus-side finish (step 13 — single coordinated PR)

Run after every renamed repo's SHAs are stable. PR title:
`chore: drop 'Project' prefix and split to Athena (@ADR-015 + @ADR-016)`.
Body: `Closes #<tracking-issue>`.

> **Human sign-off required.** Step 13's PR updates `.gitmodules`
> paths and SHAs across 11 renames plus 1 new entry; per [AGENTS.md](../../AGENTS.md/#scope),
> submodule pins are *cross-repo integration events*. A myrmidon must
> **not** enable `--auto --rebase` on this PR. The PR is held open for
> `@mvillmow` (or the on-call operator) to merge by-hand after the
> per-repo internal-touch PRs are all green. (Same gating policy as
> AI-006's ai-maestro removal PR.)

### `.gitmodules`

For each renamed repo, change the `[submodule "..."]` key, `path`, and
`url`. For Athena, add the new entry. Final structure:

```ini
[submodule "infrastructure/Argus"]
    path = infrastructure/Argus
    url = https://github.com/HomericIntelligence/Argus.git

[submodule "infrastructure/Hermes"]
    path = infrastructure/Hermes
    url = https://github.com/HomericIntelligence/Hermes.git

[submodule "provisioning/Telemachy"]
    path = provisioning/Telemachy
    url = https://github.com/HomericIntelligence/Telemachy.git

[submodule "provisioning/Keystone"]
    path = provisioning/Keystone
    url = https://github.com/HomericIntelligence/Keystone.git

[submodule "agentic/Athena"]
    path = agentic/Athena
    url = https://github.com/HomericIntelligence/Athena.git

[submodule "shared/Hephaestus"]
    path = shared/Hephaestus
    url = https://github.com/HomericIntelligence/Hephaestus.git

[submodule "shared/Mnemosyne"]
    path = shared/Mnemosyne
    url = https://github.com/HomericIntelligence/Mnemosyne.git

[submodule "ci-cd/Proteus"]
    path = ci-cd/Proteus
    url = https://github.com/HomericIntelligence/Proteus.git

[submodule "research/Odyssey"]
    path = research/Odyssey
    url = https://github.com/HomericIntelligence/Odyssey.git

[submodule "research/Scylla"]
    path = research/Scylla
    url = https://github.com/HomericIntelligence/Scylla.git

[submodule "control/Agamemnon"]
    path = control/Agamemnon
    url = https://github.com/HomericIntelligence/Agamemnon.git

[submodule "control/Nestor"]
    path = control/Nestor
    url = https://github.com/HomericIntelligence/Nestor.git

[submodule "testing/Charybdis"]
    path = testing/Charybdis
    url = https://github.com/HomericIntelligence/Charybdis.git
```

The cmake justfile recipes' `-DProject*_BUILD_TESTING=ON` flags become
`-D<Name>_BUILD_TESTING=ON`. The `_server` binary names drop the prefix:

```diff
- "ProjectAgamemnon_server" → "Agamemnon_server"
- "ProjectNestor_server"    → "Nestor_server"
- "ProjectKeystone_server" → "Keystone_server"
- "ProjectCharybdis_server"→ "Charybdis_server"
```

### `justfile`

Reach for `grep -nE 'Project[A-Z][a-z]+' justfile` first to enumerate every
touch. Then:

- Every `cd control/Project<X>` → `cd control/<X>`.
- Every `cd infrastructure/Project<X>` → `cd infrastructure/<X>`.
- Every `cd provisioning/Project<X>` → `cd provisioning/<X>`.
- Every `cd ci-cd/Project<X>` → `cd ci-cd/<X>`.
- Every `cd research/Project<X>` → `cd research/<X>`.
- Every `cd testing/Project<X>` → `cd testing/<X>`.
- Every `cd shared/Project<X>` → `cd shared/<X>`.
- Every `cd agentic/Athena` (new).
- Every `{{BUILD_ROOT}}/Project<X>` → `{{BUILD_ROOT}}/<X>`.
- Every `-DProject<X>_BUILD_TESTING=ON` → `-D<X>_BUILD_TESTING=ON`.
- Every `Project<X>_server` binary path → `<X>_server`.
- `install-python` recipe: `pip install -e shared/ProjectHephaestus` →
  `pip install -e shared/Hephaestus` (and consider adding
  `pip install -e agentic/Athena`).
- Per-component recipe names with `Project*` in their comment header —
  drop the prefix from the comment, but the recipe name stays
  (`hermes-start`, `argus-start`, `keystone-start`, etc. are already bare).
- The "Skills Marketplace (ProjectMnemosyne)" comment header →
  "Skills Marketplace (Mnemosyne)".
- The "Shared Utilities (ProjectHephaestus)" comment header → "Shared
  Utilities (Hephaestus)". Add a parallel "Agentic Plugins (Athena)"
  block with the Athena-aware recipes.
- The `atlas-review-*` recipes that invoke
  `infrastructure/ProjectArgus/dashboard/scripts/...` →
  `infrastructure/Argus/dashboard/scripts/...`.
- The `hermes-hub-down` recipe that pkill's on
  `provisioning/Myrmidons/hello-world/main.py` — unchanged, Myrmidons is
  not being renamed.

### `docs/architecture.md`

- **Component Inventory table**: every `**<project>` name → `**<bare>`.
- Add the Athena row.
- The "Project Agamemnon's REST API contract" line in *Canonical Workflow
  Field Names* → *"Agamemnon's REST API contract"*.
- The Diagram: `ProjectFoo` boxes → `<Foo>`. Edges stay the same (subjects
  unchanged per ADR-013).
- The "Remote-execution" pre-amble text uses bare names already; not
  affected.

### `CLAUDE.md`

- The repository-structure block: every project-prefixed submodule entry
  drops the prefix. Add `agentic/Athena`.
- Key-principle #2 ("ai-maestro has been removed per ADR-006.
  ProjectAgamemnon (control/ProjectAgamemnon) replaces ai-maestro's task
  coordination role.") →
  ("ai-maestro has been removed per ADR-006. **Agamemnon
  (`control/Agamemnon`)** replaces ai-maestro's task coordination role.")
- The *Common Commands* example under `bash` examples — "Start the NATS
  event bridge (ProjectHermes)" → "Start the NATS event bridge (Hermes)".
  Three lines change.
- Resource-limits prose ("hephaestus' max_workers=3") — unchanged.
- The ADR list block at top of the repo structure tree gets the two new
  ADR entries.

### `.claude/settings.json`

```diff
 {
   "enabledPlugins": {
-    "hephaestus@ProjectHephaestus": true
+    "hephaestus@Hephaestus": true,
+    "athena@Athena": true
   }
 }
```

### `docker-compose.e2e.yml`

- `context: control/ProjectAgamemnon/` → `context: control/Agamemnon/`.
- `context: control/ProjectNestor/` → `context: control/Nestor/`.
- `context: infrastructure/ProjectArgus/exporter/` →
  `context: infrastructure/Argus/exporter/`.

### `.github/PULL_REQUEST_TEMPLATE/atlas-M{1..6}.md`

- The "review charter" link
  `infrastructure/ProjectArgus/dashboard/docs/review-charter.md` →
  `infrastructure/Argus/dashboard/docs/review-charter.md`.

### `tools/github/snapshot-protection.sh` and `tools/github/remove-classic-protection.sh`

The two `REPOS` / `ALL_REPOS` arrays contain a hard-coded 15-element list.
Replace the 11 `Project*` slugs with the bare names and add `Athena`. The
list becomes:

```bash
REPOS=(Odysseus AchaeanFleet Argus Hermes Telemachy Keystone Myrmidons \
       Proteus Odyssey Scylla Mnemosyne Hephaestus Agamemnon Nestor \
       Charybdis Athena)
```

(16 entries. Athena is the 16th. Update the comment that says "all 15 repos".)

### `scripts/gen-ecosystem-table.sh`

This script *derives* the per-repo list from `.gitmodules` (see
`scripts/gen-ecosystem-table.sh:47`). It needs **no edit** — the
README ecosystem CI board updates automatically once `.gitmodules`
points at the new slugs. After the Odysseus-side PR merges, regenerate
the README with `just ecosystem-table` and `git diff README.md` should
show only the `<!-- ECOSYSTEM-CI-TABLE:START -->` block changing.

### Files that DO NOT need updates

- `scripts/gen-ecosystem-table.sh` — derives from `.gitmodules` (confirmed).
- `scripts/check-submodule-drift.sh` — derives from `.gitmodules`.
- `scripts/ecosystem-health.sh` — derives from `.gitmodules`.
- `tests/test-justfile-recipes.sh` and `tests/test-config-validators.sh` —
  assert on just recipe *names*, which are already bare (the rename
  edits only the recipe *body* paths/binary names, not the recipe
  name surface).
- `docs/runbooks/*.md` — if they mention component names, update the
  prose, but no behavioural code.
- `docs/ci-naming-convention.md` — names the CI categories, not repos.
- `docs/nats-subjects.md` (if it exists) — wire protocol subject names
  unchanged per ADR-013.

### `.github/workflows/*`

Per AGENTS.md, workflows in this repo require human review before edit.
Inspect each:

- `ci.yml` — likely no repo-name references; safe.
- `submodule-update-check.yml` — calls Bash against repo paths; runs
  the Genesis Health job — should already pick up the new submodule
  paths via `git submodule foreach`; verify before edit.
- Any workflow with hard-coded `gh api repos/HomericIntelligence/Project<X>`
  endpoint — needs the new slug. Inspect first.
- Any workflow with `uses: HomericIntelligence/Project<X>/.github/workflows/foo.yml@main`
  reusable-workflow reference — needs the new slug. Inspect first.

Do not edit `.github/workflows/` directly without coordinating with
`@mvillmow`.

### Generated content

`README.md` is partly auto-generated: the **Ecosystem CI Status** section
between the `<!-- ECOSYSTEM-CI-TABLE:START -->` and `--ECOSYSTEM-CI-TABLE:END-->`
markers is regenerated by `just ecosystem-table`. Run the regen as the
last step of the Odysseus-side PR.

## 5. Verify

Before merge:

```bash
just ci
just lint
just validate-configs
just check-doc-field-drift
# Regenerated README section:
just ecosystem-table
git diff README.md   # confirm only ECOSYSTEM-CI-TABLE section changes
# Workflow drift check (per-repo CI matrix still wired up):
grep -nE 'Project[A-Z][a-z]+' .github/workflows/* || echo "no workflow refs"
```

After merge (operator sanity):

```bash
cd /tmp && rm -rf odyssey-test && git clone --recurse-submodules https://github.com/HomericIntelligence/Odysseus.git odyssey-test
cd odyssey-test
just bootstrap && just ci
```

## 6. Roll back

If any piece fails, revert the Odysseus-side merge commit:
`git revert <merge-sha>` — submodule pins revert, the GitHub-side
redirects continue to serve the old slugs, no external surface broken.

If the Hephaestus carve-out is the failing piece: revert step 3's two
PRs and re-add the surface from back-up branch `pre-hephaestus-split`.
The Athena repo (created empty) can be archived (Settings → Archive).
The Odysseus-side PR is the last to land and the first to revert.

## References

- [ADR-015](../adr/015-drop-project-prefix.md), [ADR-016](../adr/016-split-hephaestus.md)
- [docs/architecture.md](../architecture.md)
- [AGENTS.md](../../AGENTS.md) — submodule pin-bump rules
