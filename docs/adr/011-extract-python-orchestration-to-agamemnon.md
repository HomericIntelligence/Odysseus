# ADR 011: Extract Python Orchestration Layer from Keystone to ProjectAgamemnon

**Status:** Accepted

---

## Context

ProjectKeystone's charter states unambiguously:

> **This project is EXCLUSIVELY C++20. Do NOT use Python, Mojo, or other
> languages for implementation.** Keystone is *not* an agent system, pipeline
> stage, or orchestrator. It is the invisible plumbing beneath every other
> component.

ADR-006 decoupled HomericIntelligence from ai-maestro and established
ProjectAgamemnon as the coordinator. ADR-015 subsequently extracted the C++20
HMAS orchestration hierarchy (L0 `ChiefArchitectAgent` → L3 `TaskAgent`) from
Keystone into Agamemnon.

However, a Python orchestration layer — consisting of 10 source modules
(`DAGWalker`, `TaskClaimer`, `NATSListener`, `config`, `daemon`, `logging`,
`models`, `validation`, `__main__`) and 11 accompanying test files — was left
behind in Keystone by oversight. This layer implemented:

- NATS subscription on `hi.tasks.{team_id}.{task_id}.{event}` (subject filter
  `hi.tasks.>`)
- DAG-based task dependency resolution with three-color DFS cycle detection
- Per-team async lock coalescing (`TaskClaimer`)
- Entry point for `python -m keystone` / `python -m agamemnon.orchestration`

Hosting Python orchestration logic in a C++20-only transport library violates
Keystone's charter, creates maintenance confusion (Python toolchain in a C++
build), and contradicts the role separation established in ADR-006.

Note: Issue #143 and Keystone's CLAUDE.md *cite* an "ADR-015" for this
extraction, but no such ADR exists in this repository's `docs/adr/` — the
reference is documentation drift. This ADR-011 is the authoritative,
cross-ecosystem record for the **Python** layer extraction; downstream docs
(including Keystone's) should point to ADR-011 in Odysseus rather than to the
non-existent ADR-015.

## Decision

Move all 10 Python source modules and 11 test files from
`ProjectKeystone/src/keystone/` and `ProjectKeystone/tests/` into a new package
`agamemnon.orchestration` in ProjectAgamemnon, under
`agamemnon/src/agamemnon/orchestration/`.

Specific decisions within this extraction:

1. **Package rename:** `keystone` → `agamemnon.orchestration`. All internal
   imports updated (`from keystone.X` → `from agamemnon.orchestration.X`).

2. **Env-var rename (Python-config-only):** The three Python-read environment
   variables are renamed with a deprecation shim:
   - `KEYSTONE_LOG_LEVEL` → `AGAMEMNON_LOG_LEVEL`
   - `KEYSTONE_POLL_INTERVAL` → `AGAMEMNON_POLL_INTERVAL`
   - `KEYSTONE_SHUTDOWN_TIMEOUT` → `AGAMEMNON_SHUTDOWN_TIMEOUT`

   The shim reads the new key first; falls back to the old key with a
   `DeprecationWarning`; removed in v2.0.0. **C++ env vars
   (`KEYSTONE_NATS_URL`, `KEYSTONE_NATS_SUBJECT`, `KEYSTONE_NATS_DURABLE`,
   `KEYSTONE_PROFILE`, `KEYSTONE_NATS_TLS_*`) are unchanged** — they belong
   to Keystone's C++ transport and are not in scope.

3. **NATS subject contract frozen:** The public subject filter
   `"hi.tasks.>"` and the five-part subject structure
   `hi.tasks.{team_id}.{task_id}.{event}` are preserved byte-for-byte.
   No downstream subscribers (Argus, AI Maestro) need to redeploy.

4. **Git history preserved:** Python source history was replayed from Keystone
   onto the Agamemnon branch using `git format-patch --follow | sed | git am
   --committer-date-is-author-date`, so `git log --follow` traverses the full
   pre-move history in Agamemnon.

5. **Packaging migrated:** `ProjectKeystone/pyproject.toml` (the `keystone`
   Python package declaration) and Python `pypi-dependencies` in
   `ProjectKeystone/pixi.toml` are removed. Python build dependencies are added
   to `ProjectAgamemnon/agamemnon/pixi.toml`.

6. **Re-export shim (N8) skipped:** No HomericIntelligence component outside
   Keystone imported the `keystone` Python package directly (confirmed by grep
   across all submodules). Skipping the one-release-cycle compatibility shim is
   safe.

## Consequences

**Positive:**
- Keystone is now exclusively C++20, matching its charter. The Python toolchain
  (pytest, pydantic, nats-py) is fully removed from Keystone's build.
- The orchestration logic lives alongside Agamemnon's C++ coordinator — a
  single repo holds all coordination-layer code.
- NATS subject contracts are unchanged; Argus, AI Maestro, and Hermes require
  no changes.
- `git log --follow` in Agamemnon traces Python file history back to original
  Keystone commits.
- The env-var deprecation shim gives operators a migration window before v2.0.0.

**Negative:**
- Operators running `python -m keystone` must update to
  `python -m agamemnon.orchestration`. The entry point is documented in
  Agamemnon's CLAUDE.md.
- Operators using `KEYSTONE_LOG_LEVEL`, `KEYSTONE_POLL_INTERVAL`, or
  `KEYSTONE_SHUTDOWN_TIMEOUT` for the Python daemon will see
  `DeprecationWarning` at startup until they switch to `AGAMEMNON_*` names.
  The C++ `KEYSTONE_NATS_*` and `KEYSTONE_PROFILE` variables are unaffected.

**Neutral:**
- `KeystoneLogger` and `JsonFormatter` class names are preserved in the moved
  code — renaming them is deferred to a follow-up refactor (out of scope for
  this ADR).
- `validation.py` and `logging.py` remain in `agamemnon.orchestration` for
  now; extraction to a shared utility package is a separate future decision.

## References

- [ADR 006](006-decouple-from-ai-maestro.md) — Decision to replace ai-maestro
  with native components; established Agamemnon as coordinator.
- [Issue #143](https://github.com/HomericIntelligence/Odysseus/issues/143) —
  Epic tracking this extraction across ProjectKeystone, ProjectAgamemnon, and
  Odysseus.
- ProjectAgamemnon issues: #24 (N1), #25 (N2), #26 (N3), #27 (N4), #28 (N5),
  #29 (N8) — sub-issues for each migration step.
- ProjectKeystone issues: #432 (N6 — Python layer deletion), #433 (N7 — docs
  update).
