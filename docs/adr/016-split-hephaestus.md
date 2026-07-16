# ADR 016: Split `Hephaestus` — Library vs Agentic Plugins

**Status:** Accepted

---

## Context

The current `ProjectHephaestus` repo carries two distinct concerns in one
working tree, separated by an internal import-boundary convention:

1. **A Python library** rooted at `hephaestus/` (subpackages:
   `agents`, `automation`, `benchmarks`, `ci`, `cli`, `config`,
   `datasets`, `discovery`, `forensics`, `github`, `io`, `logging`,
   `markdown`, `nats`, `resilience`, `scripts_lib`, `system`, `utils`,
   `validation`, `version`). Installed as `hephaestus` (a pip distribution
   currently named `project-hephaestus`, to be renamed under
   [ADR-015](015-drop-project-prefix.md)). The library is intentionally lean
   at its import surface and never imports from `hephaestus.automation` in
   its library subpackages.

2. **An agentic plugin/skill surface** rooted at `.claude-plugin/`,
   `.codex-plugin/`, `.agents/`, `plugins/`, and `skills/` (with `assets/`
   shipped alongside). The skills themselves (`advise`, `brainstorm`,
   `code-review`, `repo-analyze`, etc.) describe LLM-facing behaviours and
   are consumed by the agent hosts (Claude Code, Codex, Pi) through a plugin
   install contract — either git-clone into the host's plugin directory, or
   the host's package-manager surface.

The two concerns share git history and a packaging boundary today, but they
should not. The library has a slow release cadence (semantic-versioned,
backward-compatible contract for the wider ecosystem) and a Python-only
audience (pip/CI). The plugin surface has a fast release cadence (new
skills added each pipeline run, skills tested interactively with the
host) and a multi-host audience (installed into Claude Code, Codex, and Pi
via three different install mechanisms).

Compounding the friction: the `hephaestus.automation` Python subpackage —
the queue-based Claude/Codex issue-planning/implementation/PR-review
pipeline described in Hephaestus's CLAUDE.md — straddles the boundary. Its
*entry-point* is a Python library, its *operating environment* is the
agent-host CLI. Today both ends are shipped from one repo, which keeps the
library and the agent surface on the same release cadence even though they
want different ones.

The companion rename ADR ([ADR-015](015-drop-project-prefix.md)) renames the
repo from `ProjectHephaestus` to `Hephaestus`. This ADR carves the plugin
surface out into a new repo `Athena`, leaving `Hephaestus` as the pure
library, and pins the dep direction so the split is unambiguous.

## Decision

Split `ProjectHephaestus` into two repos, both prefixed under
[HomericIntelligence](https://github.com/HomericIntelligence):

| New repo                                  | Path in Odysseus | Surface                                                      |
|-------------------------------------------|------------------|--------------------------------------------------------------|
| `Hephaestus` (`hephaestus` Python pkg)    | `shared/Hephaestus`    | Library only. Retains `hephaestus/` source tree, tests, CI.        |
| `Athena` (`athena` plugin distribution)   | `agentic/Athena`       | Plugin/skill surface. `.claude-plugin/`, `.codex-plugin/`, `.agents/`, `plugins/`, `skills/`, `assets/`. |

`hephaestus.automation` **stays in Hephaestus** as a Python subpackage
behind the existing `[automation]` install extra. It is a library, not a
plugin manifest; its responsibility is the in-process queue
pipeline that drives a Claude/Codex subprocess, not the host-side plugin
install. Athena's plugin/skill code may `pip install hephaestus[automation]`
when it needs this orchestrator.

The dependency direction is one-way: **Athena depends on Hephaestus** —
Athena's `pyproject.toml` declares `hephaestus` (and optionally
`hephaestus[automation]`) as a runtime dependency. Hephaestus MUST NOT
import from Athena. The split is enforced by tooling: the
"library subpackages cannot import `hephaestus.automation`" rule that
already exists in Hephaestus's CLAUDE.md is extended to also forbid
imports from any path that names an Athena plugin, and the same static
analysis gate that enforces the library constraint today enforces this
new one.

Skill code that today lives inside Hephaestus and does `from
hephaestus.automation import ...` from inside the skills/ tree
moves into Athena *with its import statement unchanged* — `import
hephaestus.automation` still resolves after the carve-out, because
the Python package surface (`hephaestus.automation` gated behind the
`[automation]` extra) stays in Hephaestus. What changes is the
*host-side install* (the skill directory moves; the runtime import
does not). The Athena-side `pyproject.toml` declares `hephaestus`
plus `hephaestus[automation]` in its optional-dependencies so that
running skills that invoke the orchestrator continue to work without
requiring a separate `pip install` step in the host environment.

A new top-level category `agentic/` in Odysseus houses Athena:

```
Odysseus/
├── control/
├── shared/             # Hephaestus, Mnemosyne ← unchanged minus Hephaestus rename
├── agentic/            # NEW — Athena only, for now
│   └── Athena/
├── infrastructure/
├── provisioning/
├── ci-cd/
├── research/
├── testing/
```

The `agentic/` category is explicitly defined as "repos installed as
plugins/skills into agentic coding hosts (Claude Code, Codex, Pi)." Any
future agentic plugin repo lands under it.

## Consequences

**Positive:**

- Hephaestus's release cadence is decoupled from the plugin surface's.
  Library semantic-versioning is no longer forced to track "we added a
  new skill this week."
- Athena can be installed without pulling the full Hephaestus source
  tree — `pip install hephaestus` and `git clone Athena` yields the
  minimal "agent host + library" surface an agent runner needs.
- Each repo can scope its own CI: Hephaestus's `integration-tests`
  matrix can run all four CPython versions in isolation; Athena's CI
  can smoke-test plugin loading into Claude Code, Codex, and Pi
  separately.
- Repository-level rulesets and required checks can differ: Hephaestus
  keeps its existing `auto-merge-policy` + `required-checks-gate`;
  Athena can configure its own plugin-load smoke as a required check.
- The library/product boundary that Hephaestus's CLAUDE.md documents
  is now a *file system* boundary, not just a comment.

**Negative:**

- One-time carve-out is required. The current `ProjectHephaestus`,
  after ADR-015, must have the plugin/skill surface surgically
  extracted into a new repo, with `HePHAESTUS` losing the migration
  driver and `Athena` gaining it. Path-level migration aids (a
  one-shot script in Hephaestus that rewrites user-local clones'
  `~/.claude/settings.json` plugin path, etc.) belong in Hephaestus
  and follow this ADR as a one-release shim.
- Skills that currently ship co-located with the library must choose
  one home. Cross-skill dependencies that today resolve by relative
  import (`from hephaestus.automation import ...`) become
  `import hephaestus.automation` + a declared dep in Athena's
  `pyproject.toml`. That is a breaking change for any third-party
  fork that consumed the old layout; a 1-release deprecation note in
  Athena's README flags it.
- The `~/.claude/settings.json` line that currently reads
  `"hephaestus@ProjectHephaestus": true` (in Odysseus's own
  `.claude/`) must be updated to `"hephaestus@Hephaestus": true`,
  and a new line `"athena@Athena": true` added if/when Athena is
  packaged as a Claude Code plugin. (Edits are local to each
  consumer's `.claude/settings.json`; Odysseus's own entry is part
  of the Odysseus-side change list for ADR-015.)
- Two-repos coordinate releases now: a breaking-change in
  `hephaestus.automation` touches both Hephaestus and Athena.
  Mitigation: pin Athena's `hephaestus` dep to a minimum version
  range, document the supported pair in both READMEs, and surface
  mismatch errors in Athena's plugin-load smoke test.

**Neutral:**

- The atomic carve-out happens once, but the consequences for any
  downstream consumer are perennial (they now call two packages,
  not one).
- The plugin manifest format for Athena is whatever Claude Code /
  Codex / Pi expect today; if and when those hosts converge on a
  standard, only Athena needs an update, not Hephaestus.

## References

- [ADR 015](015-drop-project-prefix.md) - Companion rename decision; the
  two ADRs land together.
- [ADR 013](013-hmas-mesh-wire-contracts.md) - Wire protocol whose subject
  names are intentionally NOT touched by this ADR.
- `shared/ProjectHephaestus/CLAUDE.md` - The document that first articulated
  the library-vs-product boundary this ADR makes physical.
- `docs/runbooks/rename-and-split.md` - The per-submodule migration runbook
  for the atomic carve-out.
