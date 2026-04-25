# ADR 007: Replace Symlinks with Real Git Submodules

**Status:** Proposed

---

## Context

Odysseus is the meta-repo for the HomericIntelligence ecosystem. It declares
15 submodule entries in `.gitmodules`, each with a proper GitHub URL under
`https://github.com/HomericIntelligence/`. However, 12 of those 15 entries are
actually symlinks (git mode `120000`) pointing to absolute local paths on the
original developer's machine (under `/home/mvillmow/`), not real git submodule
gitlinks.

The 12 symlinked paths are:

- `infrastructure/AchaeanFleet` → `/home/mvillmow/AchaeanFleet`
- `infrastructure/ProjectArgus` → `/home/mvillmow/ProjectArgus`
- `infrastructure/ProjectHermes` → `/home/mvillmow/ProjectHermes`
- `provisioning/ProjectTelemachy` → `/home/mvillmow/ProjectTelemachy`
- `provisioning/ProjectKeystone` → `/home/mvillmow/ProjectKeystone`
- `provisioning/Myrmidons` → `/home/mvillmow/Myrmidons`
- `ci-cd/ProjectProteus` → `/home/mvillmow/ProjectProteus`
- `research/ProjectOdyssey` → `/home/mvillmow/ProjectOdyssey`
- `research/ProjectScylla` → `/home/mvillmow/ProjectScylla`
- `shared/ProjectMnemosyne` → `/home/mvillmow/ProjectMnemosyne`
- `shared/ProjectHephaestus` → `/home/mvillmow/ProjectHephaestus`

Only 3 of the 15 are proper gitlinks (git mode `160000`), functioning as real
submodules:

- `control/ProjectAgamemnon`
- `control/ProjectNestor`
- `testing/ProjectCharybdis`

This happened because the original developer used symlinks for convenience
during initial local development — changes in the local repo checkouts were
instantly visible under Odysseus without any submodule update ceremony.

This approach breaks multiple critical workflows:

1. **Cloning:** `git clone --recurse-submodules` cannot resolve absolute paths
   to another machine's filesystem. A fresh clone produces broken symlinks for
   12 of 15 components.
2. **CI/CD:** Containers and CI runners do not have `/home/mvillmow/` on their
   filesystem. Any pipeline that depends on submodule content fails silently or
   errors out.
3. **Onboarding:** New developers cannot bootstrap the ecosystem from a single
   `git clone`. They must manually discover and clone each repo, then recreate
   the symlinks.
4. **Disaster recovery:** The repository cannot be fully reconstituted from
   GitHub alone. Losing the original developer's machine means losing the
   ability to resolve 12 of the 15 component paths.

The three already-correct gitlinks (ProjectAgamemnon, ProjectNestor,
ProjectCharybdis) prove that the real submodule model works and can coexist
with the rest of the ecosystem.

## Decision

Convert all 12 symlinks to real git submodule gitlinks. The conversion workflow
for each symlink is:

```bash
git rm <symlink-path>
git submodule add <github-url> <path>
git -C <path> checkout main
```

After conversion, all 15 entries will be proper gitlinks (mode `160000`), and
`git ls-files -s` will show no remaining `120000` entries under the submodule
paths.

### Why submodules over symlinks

- **Portability:** `git clone --recurse-submodules` works on any machine, any
  OS, any CI runner — no host-specific paths required.
- **CI/CD compatibility:** Pipelines can initialize submodules with standard
  git commands. No assumptions about the host filesystem.
- **Disaster recovery:** The entire ecosystem is reconstitutable from GitHub.
  Every component is referenced by URL and pinned by SHA in Odysseus.
- **Git-native tooling:** `git submodule update`, `git diff --submodule`,
  `git submodule status`, and IDE integrations all work correctly with real
  gitlinks. They do not work with symlinks.

### How myrmidons work with submodules

Myrmidon workers operate within individual repo worktrees, not the Odysseus
meta-repo. A myrmidon receives a task scoped to a specific repository (e.g.,
ProjectArgus), clones or checks out that repo, performs its work, and reports
results back through Agamemnon. The submodule relationship in Odysseus is for
coordination and integration pinning, not for myrmidon task execution.

### How worktrees work with submodules

`git worktree add` creates an isolated working copy of Odysseus. Within that
worktree, submodules are initialized via `git submodule update --init` to get a
self-contained copy of the full ecosystem. Each worktree can independently
track different submodule SHAs without interfering with other worktrees or the
main checkout.

### How sub-agents work with submodules

Each Claude Code sub-agent is launched with `isolation: "worktree"` for safe
parallel work. Agents operate within a single submodule repo, not across the
full Odysseus tree. This isolation ensures that concurrent agents modifying
different repos cannot conflict with each other or with the developer's main
working copy.

### Task scoping principle

All implementation work happens in individual submodule repos. Odysseus
coordinates; repos execute. Cross-cutting changes that span multiple repos are
decomposed into per-repo sub-tasks by ProjectAgamemnon, each dispatched to a
myrmidon or sub-agent operating within the relevant repo's worktree.

## Consequences

**Positive:**
- `git clone --recurse-submodules` works out of the box on any machine.
- CI/CD pipelines and containers work without host-specific path assumptions.
- New developers and agents onboard with a single clone command.
- Disaster recovery is possible: the entire ecosystem is reconstitutable from
  GitHub alone.
- Submodule SHAs in Odysseus serve as a cross-repo integration checkpoint — a
  known-good configuration of the full ecosystem at a point in time.

**Negative:**
- Developers on the original host lose the convenience of symlinked local edits
  being instantly visible in Odysseus. Changes in a submodule repo must be
  committed there, then the submodule pin in Odysseus updated with a separate
  commit.
- `git submodule update` adds a step after pulling Odysseus. Developers must
  run `git submodule update --init --recursive` or use
  `git pull --recurse-submodules` to stay current.
- Submodule pin updates require an explicit commit in Odysseus after changes
  land in submodule repos. This is intentional (pins represent integration
  checkpoints) but adds friction.

**Neutral:**
- The `.gitmodules` file requires no changes. All 15 entries already have
  correct GitHub URLs pointing to
  `https://github.com/HomericIntelligence/<RepoName>.git`.
- The three already-correct gitlinks (ProjectAgamemnon, ProjectNestor,
  ProjectCharybdis) require no action.
- Odysseus remains a coordination-only meta-repo with no application code.
  This ADR reinforces that role.
