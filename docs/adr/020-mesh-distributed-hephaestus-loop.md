# ADR 020: Distribute the Hephaestus Automation Loop Across the Mesh

**Status:** Proposed

**Extends:** [ADR 013](013-hmas-mesh-wire-contracts.md)

---

## Context

The Hephaestus automation loop — the `state:*`-labeled pipeline that drives a
GitHub issue through planning, plan review, implementation, PR review, merge,
and learning — is today a **single-device program**: one operator-launched
`hephaestus-automation-loop` process runs an in-process thread-pool worker
pool on one host. All stage sequencing lives in memory
(`hephaestus/automation/pipeline/routing.py`); Claude/Codex/Pi agents are
invoked as local child processes; restart recovery works only because GitHub
labels and comments are the durable journal.

The rest of the ecosystem already assumes distribution. ADR-013 defined
role-addressed dispatch (`hi.myrmidon.{domain}.{role}.task.{task_id}`),
JetStream lease semantics, state-fact subjects, epic conventions, and a
one-to-one mapping between Agamemnon's HMAS task states and the Hephaestus
labels. The provisioning side is scaffolded but idle: AchaeanFleet ships an
`achaean-mesh` vessel expecting a `Hephaestus[mesh]` extra and a
`hephaestus-mesh-worker` entry point that do not exist yet; the Myrmidons repo
already carries mesh pool manifests for `pipeline.chief-architect`,
`pipeline.task-agent`, and `research.chief-architect`.

Meanwhile the loop's execution substrate changed: the operator no longer holds
a Claude account, and Hephaestus' runtime abstraction gained an opencode
adapter (`AgentName = Literal["claude", "codex", "pi", "opencode"]`). The
mesh must therefore be provider-neutral in fact, not just in code.

Finally, the HMAS hierarchy itself has two competing shapes: Agamemnon
dispatches against a 4-level role ladder, while Odyssey maintains the more
detailed 6-level / 30-agent hierarchy (`agents/hierarchy.md`, mirrored in its
`.claude/agents/*.md` frontmatter definitions with `level`, `delegates_to`,
and `receives_from`). Agent definitions are currently scattered across
consumer repos, contradicting Myrmidons' role as GitOps source of truth.

## Decision

### 1. Decentralized stage chain — no conductor

Each loop stage becomes a mesh worker serving one role-addressed queue. When
a worker finishes its stage it writes the resulting `state:*` label
(exclusively, via the existing Hephaestus mutation + readback path), then
**publishes the next stage's dispatch packet itself**. There is no central
conductor daemon. Crash recovery is label-driven: a stateless
`hephaestus-mesh-seed` CLI rescans labeled issues across watched repos and
(re)publishes packets for items whose current label maps to a stage without an
in-flight lease. Restart = re-run remains the recovery contract.

### 2. Stage ↔ role map

| Loop stage | Queue (`hi.myrmidon.pipeline.{role}.task.>`) | Lane | Notes |
|---|---|---|---|
| Intake | — | — | Epic children arrive labeled `state:needs-plan` |
| Planning | `chief-architect` | Planning | advise-before gate |
| Plan review | `plan-reviewer` (new) | Review | read-only scope |
| Implementation | `task-agent` | Implementation | writer scope |
| PR review | `pr-reviewer` (new) | Review | sole writer of `implementation-go/-no-go` |
| Merge | `merger` (new) | Mechanical | see §3 |
| Learn | aux queue post-merge | Mechanical→Review | learn-after gate |

### 3. Merger agent

A dedicated mechanical worker subscribes to impl-go review outcomes. On each
packet it independently investigates: fresh head-SHA readback, zero open
review threads, exclusive-label consistency, and CI status. If all criteria
hold it arms squash auto-merge; otherwise it writes
`state:implementation-no-go` and publishes a remediation packet back to the
`task-agent` queue carrying the failing evidence. Bounded by the existing
merge retry budget (5); exhaustion follows the standard `state:skip` path.
The merger runs with least-scoped credentials (merge + label write only) in
its own vessel.

### 4. Provider-neutral lanes; opencode-first deployment

The agent backend is per-manifest configuration resolved through the
existing Hephaestus runtime abstraction. The operator lane runs **opencode**;
Claude remains fully available for other contributors. Models are assigned
per **lane**, pinned in Myrmidons manifests (`model:` field), never in code:
Planning, Implementation, Review, and Mechanical lanes may each use different
models. Changing a lane model is a one-line manifest edit.

### 5. Odyssey's 6-level hierarchy is the canonical HMAS structure

Myrmidons adopts Odyssey's 6-level / 30-agent hierarchy
(`research/Odyssey/agents/hierarchy.md`) as the canonical mesh structure:
L0 meta-orchestrator (chief-architect), L1 six section orchestrators, L2 four
design/review-routing agents, L3 seventeen specialists, L4 five engineers,
L5 junior engineers. The `.claude/agents/*.md` frontmatter format
(`name/description/level/phase/tools/model/delegates_to/receives_from`)
becomes the import source; definitions land in a new
`provisioning/Myrmidons/agents/hierarchy/` area with a lint/sync gate so
per-repo copies validate against (or derive from) Myrmidons. Domain-specific
leaves (e.g., Mojo specialists) generalize per domain; level semantics,
delegation graph, and model-tier mapping stay fixed.

Agamemnon gains a work item: extend `mesh_role_name()` from 4 levels to the
6-level naming so dispatch subjects address every hierarchy level.

### 6. GitHub remains the sole backing store; packets stay pointers

Every milestone is tracked as a **GitHub epic with child issues in the repo
that owns most of the milestone's work** (per-repo epics). Every child issue
is exactly one dispatchable task. NATS packets carry only the ADR-013 pointer
envelope (`repo`, `issue`, `epic_key`, `branch`, `attempt`, budget counters);
workers read the full task description from GitHub at claim time. Labels
remain the only journal; Agamemnon's store remains the only task tree;
NATS carries facts, never authority.

### 7. Telemachy registers requirements; a planner agent plans the epic

Telemachy does not plan. Milestone workflow YAMLs encode **requirements,
goals, invariants, and research context**, then direct Telemachy's executor
to launch a planner sub-agent for the epic decomposition. That planner runs
under the **athena:advise** skill (planning mode: Mnemosyne knowledge-tree
sync before any planning, fail-closed), produces the child-issue breakdown,
and Telemachy registers the epic + children (`state:needs-plan`) and
publishes `hi.pipeline.epic.{key}.registered`.

### 8. Advise-before / learn-after are mandatory gates

Every planning surface (epic planning, per-issue planning stage) runs
athena:advise before generating plans; every merged change triggers
athena:learn post-merge, opening a Mnemosyne PR backed by a host-owned
delivery receipt. Unavailability degrades to a recorded SKIP breadcrumb,
never silent omission.

### 9. Staged rollout ladder

M0 contracts → M1 keystone worker (single host, multi-thread) → M2
multi-process per role → M3 containerized pipeline domain on one host →
M4 full-pipeline dogfood (mesh drives real backlog) → M5 research domain →
M6 idea-watcher agent + web interview interface. Until a capability lands,
the single-device `hephaestus-automation-loop` remains the fallback driver;
both modes share labels and journal, so handoff is seamless.

## Consequences

**Positive:**
- The PoC loop and the production mesh become the same system; no rewrite
  cliff between validation and operation.
- Horizontal scale: stages parallelize across hosts under the existing
  ≤3-heavy-agents-per-host budget (MaxAckPending=3).
- Provider and model choice become operational config, immune to account or
  vendor changes.
- One canonical hierarchy ends the 4-level/6-level and scattered-definition
  drift.
- Advise/learn gates make institutional memory flow through Mnemosyne on
  every task.

**Negative:**
- More moving parts than the conductor alternative: next-dispatch logic now
  executes inside N workers instead of one process; misrouting bugs surface
  as lost items until the seeder re-walks labels.
- The merger duplicates some merge_wait verification logic; drift risk
  mitigated by extracting the shared proof module into the library both use.
- Six-level role naming requires coordinated Agamemnon + Myrmidons changes
  (cross-repo integration event).
- Per-lane models complicate cost attribution and rate-limit budgeting.

**Neutral:**
- The single-device loop stays supported indefinitely; it is the same library
  with a different executor binding.
- Legacy `e2e/claude-myrmidon.py` subjects remain deprecated; the new worker
  is ADR-013-native and the old harness migrates or retires at M4.

## References

- [ADR 013](013-hmas-mesh-wire-contracts.md) — wire contracts this ADR builds on
- [ADR 016](016-split-hephaestus.md) — Hephaestus library vs Athena plugins split
- [ADR 009](009-defer-multi-host-nomad-scheduling.md) — multi-host scheduling deferral
- Odyssey hierarchy: `research/Odyssey/agents/hierarchy.md`
- Hephaestus automation architecture: `shared/Hephaestus/docs/architecture.md`
