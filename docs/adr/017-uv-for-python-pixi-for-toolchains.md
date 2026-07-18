# ADR 017: uv for Pure-Python Repos, pixi Where a Conda Toolchain Is Required

**Status:** Proposed

---

## Context

The ecosystem standardized on [pixi](https://pixi.sh) as the single environment
and task manager across all 14 HomericIntelligence repositories. Every repo
carries a `pixi.toml`, resolves its environment from `conda-forge` (plus, for
Odyssey, the Modular MAX channels), and drives all task execution through
`pixi run <task>` and `just` recipes that wrap `pixi`.

pixi was chosen because it can manage **three** kinds of dependency in one lock:

1. **conda packages** — including non-Python toolchains: the Mojo compiler
   (`mojo` from `conda.modular.com`), C++ build tools (`cmake`, `ninja`,
   `cxx-compiler`, `conan`, `clang-tools`, `gtest`), and CLI tools (`jq`,
   `go-yq`).
2. **PyPI packages** — via `[pypi-dependencies]`.
3. **system requirements** — libc/glibc floors, platform targets.

Meanwhile [uv](https://docs.astral.sh/uv/) has become the fastest, most
ergonomic **Python** package/project manager: a single static binary, a
universal cross-platform `uv.lock`, `uv sync`/`uv run`/`uv add`, and `uvx` for
ephemeral tools. There is ecosystem pressure to adopt `uv <command>` in place of
`pixi <command>` and `pip <command>` for speed and simplicity.

The problem: **uv resolves only from PyPI. It cannot install a compiler, conan,
or the Mojo toolchain**, because those are conda packages with no equivalent
PyPI wheel. A survey of the 14 repos' `pixi.toml` `[dependencies]` (conda)
blocks makes the split concrete:

| Repo | Conda toolchain in `[dependencies]` | uv-viable? |
|------|-------------------------------------|------------|
| ProjectScylla | python, pip, pytest, ruff, pre-commit (all Python/PyPI-available) | **Yes** |
| ProjectHephaestus | python, pip, pydantic, pygments, requests, pygithub | **Yes** |
| ProjectMnemosyne | python, pyyaml | **Yes** |
| ProjectOdyssey | **`mojo`** (Modular conda channel), numpy, jinja2, … | **No** (Mojo compiler is conda-only) |
| ProjectAgamemnon | **cmake, ninja, cxx-compiler, conan, clang-tools, openssl, libcurl** | **No** (C++ toolchain) |
| ProjectNestor | **cmake, ninja, cxx-compiler, conan, clang-tools** | **No** (C++ toolchain) |
| ProjectKeystone | **cmake, ninja, conan, cxx-compiler, gtest, pkg-config** | **No** (C++ toolchain) |
| ProjectCharybdis | **cmake, ninja, cxx-compiler, conan, clang-tools** | **No** (C++ toolchain) |
| Myrmidons | **jq, go-yq** (+ just) | **No** (non-Python CLI tools) |
| AchaeanFleet, ProjectArgus, ProjectHermes, ProjectTelemachy, ProjectProteus | `just` + Python tooling; no compiler/Mojo | **Partial** (Python parts yes; `just` stays conda/system) |

Forcing uv onto the C++/Mojo/CLI-tool repos would mean re-sourcing every
toolchain outside conda (Mojo via the Modular native installer, cmake/clang/conan
via apt or system packages, jq via system), rewriting the CI bootstrap of every
one of those repos, and losing pixi's single reproducible lock over the whole
toolchain. That is a much larger, higher-risk change than a package-manager swap
and is explicitly **out of scope** for this decision.

## Decision

Adopt a **split standard** for Python environment and task management:

1. **uv is the standard for pure-Python repositories.** A repo qualifies as
   pure-Python when its `pixi.toml` `[dependencies]` block contains **no conda
   package that is unavailable on PyPI** — in practice, no `mojo`, no C++
   toolchain (`cmake`/`ninja`/`cxx-compiler`/`conan`/`clang-tools`/`gtest`), and
   no non-Python CLI tool (`jq`/`go-yq`). Today this is **ProjectScylla,
   ProjectHephaestus, and ProjectMnemosyne**. These repos migrate to:
   - `pyproject.toml` as the single source of dependency truth, with
     `[tool.uv]`/`[dependency-groups]` for dev/optional groups,
   - a committed `uv.lock`,
   - `uv sync` / `uv run <task>` / `uv add` in CI, docs, and local workflows,
   - `pip install` replaced by `uv pip install` / `uv add`,
   - `pixi.toml` removed.

2. **pixi remains the standard where a conda toolchain is required.** Odysseus
   (Mojo), Agamemnon/Nestor/Keystone/Charybdis (C++), and Myrmidons (jq/go-yq)
   keep `pixi.toml` and `pixi run`, because uv cannot install their toolchains.
   This is not technical debt — it is the correct tool for a conda-toolchain
   repo.

3. **`just` is retained as the task-runner front door in every repo,** uv- or
   pixi-backed. Recipes in uv repos invoke `uv run`; recipes in pixi repos invoke
   `pixi run`. Callers keep typing `just <task>`, so the split is invisible to
   day-to-day use and to cross-repo tooling.

4. **Reassessment trigger:** if the Modular MAX/Mojo toolchain and the C++
   toolchains gain first-class non-conda distribution that uv (or `uvx`/system
   packages) can drive reproducibly, a superseding ADR may extend uv to those
   repos. Until then, do **not** attempt to force uv onto a conda-toolchain repo.

## Consequences

**Positive:**

- The three pure-Python repos gain uv's speed, a universal cross-platform lock,
  and a simpler single-file (`pyproject.toml`) dependency source, removing the
  pixi/pyproject dual-source drift that has already caused CI breakage (e.g. a
  dev-dependency bumped in `pyproject.toml` but not in `pixi.toml`
  `[feature.dev.pypi-dependencies]`, leaving pip-users and pixi-users on
  divergent tool versions).
- `pip install` is eliminated from those repos in favor of uv's resolver.
- The standard is explicit and testable: "does the repo need a conda toolchain?"
  is a mechanical check, so future repos know which manager to pick without
  debate.

**Negative:**

- The ecosystem now runs **two** Python environment managers instead of one.
  Mitigation: `just` hides the difference at the call site, and this ADR plus a
  one-line note in each repo's `CLAUDE.md` records which manager a repo uses and
  why.
- Contributors switching between a uv repo and a pixi repo must remember the repo
  uses a different backend. Mitigation: the `just` front door and the per-repo
  CLAUDE.md note.
- The goal of a *single* ecosystem-wide `uv <command>` standard is not fully
  achievable while the C++/Mojo toolchains are conda-only; this ADR records the
  reason so the partial adoption is a deliberate, documented boundary rather than
  an oversight.

**Neutral:**

- No change to the C++/Mojo/CLI-tool repos' workflows; they continue exactly as
  before with pixi.
- `just` remains the canonical task entry point everywhere, so runbooks and
  cross-repo automation that call `just <task>` are unaffected.

## References

- [uv documentation](https://docs.astral.sh/uv/)
- [pixi documentation](https://pixi.sh)
- ADR 011: Extract Python Orchestration to Agamemnon (established which repos are
  Python vs C++/Mojo)
- Migration PRs: ProjectScylla, ProjectHephaestus, ProjectMnemosyne (uv adoption)
