# ADR 018: uv Is the Ecosystem-Wide Standard — Toolchains via PyPI, apt, and the Mojo pip Package

**Status:** Proposed

**Supersedes:** [ADR 017](017-uv-for-python-pixi-for-toolchains.md)

---

## Context

[ADR 017](017-uv-for-python-pixi-for-toolchains.md) adopted a **split** standard:
uv for the three pure-Python repos (Scylla, Hephaestus, Mnemosyne) and pixi for
everyone else, on the premise that uv "physically cannot" install the conda
toolchains the C++/Mojo/CLI repos depend on — the Mojo compiler, `cmake`,
`ninja`, `conan`, `cxx-compiler`, `clang-tools`, and `jq`/`go-yq`.

That premise was **wrong**, and this ADR corrects it. Every one of those
toolchains has a non-conda source that uv or the CI runner can provide:

| Toolchain | Non-conda source |
|-----------|------------------|
| **Mojo compiler** | `uv pip install mojo` / `uv add mojo` (Mojo v0.25.6+, Sept 2025, ships compiler + stdlib + LSP + debugger as a PyPI wheel; `--prerelease allow` + `--extra-index-url https://modular.gateway.scarf.sh/simple/` for pinned dev builds) |
| **cmake** | `cmake` PyPI wheel (bundles the cmake binary) |
| **ninja** | `ninja` PyPI wheel (bundles the ninja binary) |
| **conan** | `conan` PyPI wheel (`uv pip install conan`) |
| **cxx-compiler** | system `gcc`/`g++`/`clang` — preinstalled on GitHub ubuntu runners, or `apt-get install` |
| **clang-tools** (clang-tidy/clang-format) | `apt-get install clang-tidy clang-format`, or the `clang-format`/`clang-tidy` PyPI wheels |
| **gcovr** | `gcovr` PyPI wheel |
| **openssl / libcurl (dev headers)** | `apt-get install libssl-dev libcurl4-openssl-dev` |
| **gtest** | vendored via `conan`/CMake FetchContent, or `apt-get install libgtest-dev` |
| **jq / go-yq** | `apt-get install jq`; `yq` via its release binary or `apt` |
| **just** | the pinned `extractions/setup-just` GitHub Action (already used ecosystem-wide) |

So uv can be the **single** Python environment/task manager across the entire
ecosystem. The Python dependencies (and, for Odyssey, the Mojo compiler itself)
come from uv against PyPI; the remaining native/system pieces come from PyPI
binary wheels, `apt`, or pinned setup-actions — none of which require conda or
pixi. `just` remains the task front door in every repo, backed by `uv run`.

The value of a single standard: no dual pixi/uv split to remember, no pixi.toml
↔ pyproject drift (which already broke CI in Hermes), one lockfile format
(`uv.lock`) everywhere, and uv's speed and universal cross-platform resolution
for all repos.

## Decision

**uv is the ecosystem-wide standard for Python environment and task management.
pixi is removed from every HomericIntelligence repository.**

1. Every repo uses `pyproject.toml` as its single dependency source, a committed
   `uv.lock`, and `uv sync` / `uv run` / `uv add` in CI, docs, and local
   workflows. `pip install` is replaced by `uv pip install` / `uv add`.
   `pixi.toml` and `pixi.lock` are deleted.

2. **Native/system toolchains are sourced outside conda:**
   - **Odyssey (Mojo):** `uv add mojo` (with `--prerelease allow` and the
     Modular index for the pinned dev build) — the Mojo compiler is a uv-managed
     dependency like any other.
   - **C++ repos (Agamemnon, Nestor, Keystone, Charybdis):** `cmake`, `ninja`,
     `conan`, `gcovr` (and `clang-format`/`clang-tidy` where a wheel exists) come
     from PyPI via a uv dev/build dependency group; `gcc`/`g++`/`clang` and the
     `-dev` header packages come from the CI runner's `apt` (they are already
     present on ubuntu runners) or an explicit `apt-get install` step.
   - **Myrmidons:** `jq`/`yq` from `apt` (or release binaries); `uv` for the
     Python tooling.

3. **`just` remains the task front door** in every repo, backed by `uv run`.

4. **Required CI check-run names are preserved** during migration — only the job
   **bodies** change from `pixi run`/`setup-pixi` to `uv run`/`setup-uv` (+ the
   toolchain `apt`/wheel steps). Renaming a required status context would
   deadlock the merge queue, so names stay identical. `deps/version-sync` moves
   from a pixi.toml↔pyproject comparison to `uv lock --check`.

5. **Migration order (de-risked):** Odyssey (Mojo — the highest-risk toolchain)
   is proven through CI + the review gate first; the four C++ repos and Myrmidons
   follow the same pattern. Each is a single gated PR that must pass
   `review-pr-strict`.

## Consequences

**Positive:**

- One environment manager, one lockfile format, no pixi/uv split to remember and
  no pixi.toml↔pyproject drift class of bug.
- uv's speed and universal cross-platform lock for every repo, including the
  C++/Mojo ones.
- The Mojo toolchain becomes an ordinary uv-managed dependency, versioned in
  `uv.lock` alongside the rest — more reproducible than a separate conda channel
  pin.

**Negative:**

- Larger, higher-risk migration than ADR 017: each C++/Mojo repo's toolchain
  bootstrap is rewritten (conda `[dependencies]` → PyPI wheels + `apt` +
  `uv add mojo`). Mitigation: prove Odyssey first; keep required check-run names
  stable; gate every PR; land one repo at a time.
- CI now depends on PyPI binary-wheel availability for `cmake`/`ninja`/`conan`
  and on the Modular PyPI index for Mojo, rather than a single conda solve.
  Mitigation: pin exact versions in `uv.lock`; the Modular index is the vendor's
  own supported distribution channel.
- Some `-dev` header packages and `clang-tidy`/`clang-format` may need an
  explicit `apt-get install` step where no maintained PyPI wheel exists.
  Mitigation: documented per-repo; ubuntu runners already carry most of them.

**Neutral:**

- `just` remains the canonical task entry point everywhere, so runbooks and
  cross-repo automation calling `just <task>` are unaffected.
- The reproducibility surface shifts from conda-forge + Modular conda channels to
  PyPI + the Modular PyPI index + a small pinned `apt` set — equivalent
  guarantees, different provenance.

## References

- [Install Mojo | Modular](https://docs.modular.com/mojo/manual/install/) —
  `uv pip install mojo` / `uv add mojo` (v0.25.6+)
- [mojo · PyPI](https://pypi.org/project/mojo/)
- [uv documentation](https://docs.astral.sh/uv/)
- ADR 017 (superseded): uv for Pure-Python Repos, pixi Where a Conda Toolchain Is Required
- Reference migrations: Hephaestus (PR #2236), Scylla (PR #2054), Mnemosyne (PR #3127)
- Follow-up migration PRs: Odyssey, Agamemnon, Nestor, Keystone, Charybdis, Myrmidons
