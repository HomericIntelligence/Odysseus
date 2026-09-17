# ADR 020: Distribute the Hephaestus Automation Loop Across the Mesh

**Status:** Proposed

**Extends:** [ADR 013](013-hmas-mesh-wire-contracts.md)

> **Proposal status:** The distributed stages, hierarchy, gates, and rollout
> below are desired state. Existing M0 artifacts are implementation evidence,
> not acceptance or proof that the complete mesh is deployed.

---

## Context

The Hephaestus automation loop — the `state:*`-labeled pipeline that drives a
GitHub issue through planning, plan review, implementation, PR review, merge,
and learning — is today a **single-device program**: one operator-launched
`hephaestus-automation-loop` process runs an in-process thread-pool worker
pool on one host. All stage sequencing lives in memory
(`hephaestus/automation/pipeline/routing.py`); the configured agent adapter is
resolved per invocation and launched as a local child process; restart recovery
works only because GitHub labels and comments are the durable journal.

The rest of the ecosystem already assumes distribution. Proposed ADR-013 defines
role-addressed dispatch (`hi.myrmidon.{domain}.{role}.task.{task_id}`),
JetStream lease semantics, state-fact subjects, epic conventions, and a
one-to-one mapping between Agamemnon's HMAS task states and the Hephaestus
labels. The provisioning side is scaffolded but idle: AchaeanFleet ships an
`achaean-mesh` vessel expecting a `Hephaestus[mesh]` extra and a
`hephaestus-mesh-worker` entry point that do not exist yet; the Myrmidons repo
already carries mesh pool manifests for `pipeline.chief-architect`,
`pipeline.task-agent`, and `research.chief-architect`.

Provider availability and selection are operational state. Hephaestus resolves
the configured adapter at each invocation, so the mesh wire and role/stage
routing must remain provider-neutral rather than encoding one operator's
account state or a static adapter catalog.

Finally, two different kinds of role have been conflated. Agamemnon and
Myrmidons use runtime mesh roles to route and provision work. Odyssey's former
6-level / 30-agent hierarchy instead described repository instruction roles
and delegation guidance. The modernization retains nine Odyssey instruction
roles with live consumers; it does not turn that instruction catalog into
runtime topology. Runtime manifests and repository instructions therefore need
separate owners and validation boundaries.

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
| Planning | `chief-architect` | Planning | contextually selected knowledge lookup |
| Plan review | `plan-reviewer` (new) | Review | read-only scope |
| Implementation | `task-agent` | Implementation | writer scope |
| PR review | `pr-reviewer` (new) | Review | writes the initial `implementation-go/-no-go` outcome |
| Merge | `merger` (new) | Mechanical | may downgrade GO on failed fresh evidence; see §3 |
| Learn | optional aux queue post-merge | Mechanical→Review | evidence-backed reusable lesson only |

### 3. Merger agent

A dedicated mechanical worker subscribes to impl-go review outcomes. On each
packet it independently investigates: a fresh PR head-SHA readback, exactly
one authenticated terminal Athena `GO` carrier whose review commit and
`artifact_binding.revision` both equal that freshly read head, a valid carrier
chain, zero open review threads, exclusive-label consistency, and CI status
bound to the same head. It repeats the head and review-snapshot readback before
arming merge and fails closed if either changed. A missing, stale, ambiguous,
or superseded carrier is not merge authority. If all criteria hold, it reads
the repository's live merge and auto-merge settings and uses only an enabled
method; otherwise it writes
`state:implementation-no-go` and publishes a remediation packet back to the
`task-agent` queue carrying the failing evidence. Bounded by the existing
merge retry budget (5); exhaustion follows the established `state:skip`
transition and records the actual failing evidence.
The merger runs with least-scoped credentials (merge + label write only) in
its own vessel.

### 4. Provider-neutral lanes

The agent backend is per-invocation or per-manifest configuration resolved
through the existing Hephaestus runtime abstraction. This ADR adds no provider,
model, role, or lane default. Planning, Implementation, Review, and Mechanical
lanes may use different explicit assignments without encoding them in the wire
contract.

### 5. Runtime roles and repository instruction roles remain separate

Myrmidons owns only the runtime role manifests required by the stage-to-role
map in section 2 and other current mesh consumers. Each runtime role must have
an exact current routing consumer. Agamemnon continues to interpret roles
through its existing wire contract; this proposal does not extend its role
ladder merely to mirror an instruction catalog.

Odyssey retains these nine repository instruction roles:
`chief-architect`, `implementation-engineer`, `ci-failure-analyzer`,
`code-review-orchestrator`, `general-review-specialist`,
`mojo-language-review-specialist`, `numerical-stability-specialist`,
`security-review-specialist`, and `test-review-specialist`. Odyssey owns their
instruction definitions and migrates every live consumer to one retained role
or a classified removal. The former 6-level / 30-agent hierarchy is not
imported into Myrmidons and does not create queues, credentials, models, or
runtime authority.

Structural checks validate runtime role references against Myrmidons and
instruction-role references against Odyssey. They also reject any unapproved
mapping that would make a repository instruction role a runtime role. Models
remain external runtime configuration rather than a fixed role-to-tier map.

### 6. GitHub supplies the durable work journal; packets stay pointers

In this proposal, every milestone is tracked as a **GitHub epic with child
issues in the repo that owns most of the milestone's work** (per-repo epics).
Every child issue is exactly one dispatchable task. NATS packets carry only the
ADR-013 pointer envelope (`repo`, `issue`, `epic_key`, `branch`, `attempt`,
budget counters); workers read the full task description from GitHub at claim
time. GitHub issues and automation-owned labels provide the durable work
description and journal. Agamemnon's configured store remains the task-tree
authority; this proposal does not change its default store or make GitHub a
backing store unless that write-through mode is configured. NATS carries
facts, never authority.

### 7. Telemachy registers requirements; a planner agent plans the epic

Telemachy does not plan. Milestone workflow YAMLs encode **requirements,
goals, invariants, and research context**, then direct Telemachy's executor
to launch a planner sub-agent for the epic decomposition. That planner runs
with a discriminating knowledge lookup when the task benefits from Mnemosyne
guidance, produces the child-issue breakdown, and Telemachy registers the epic
+ children (`state:needs-plan`) and publishes
`hi.pipeline.epic.{key}.registered`. Knowledge unavailability is disclosed and
does not stop unrelated planning unless the requested outcome genuinely
depends on that knowledge.

### 8. Knowledge skills remain contextual

Planning selects `athena:advise` only when its trigger matches the work.
Post-merge processing selects `athena:learn` only for a reusable,
evidence-backed lesson that is not already present. Skill selection never
broadens task authority; any skill-caused pause or divergence is disclosed.
An unavailable optional knowledge path is recorded truthfully without
converting the primary task into completion or failure.

### 9. Staged rollout ladder

M0 contracts → M1 keystone worker (single host, multi-thread) → M2
multi-process per role → M3 containerized pipeline domain on one host →
M4 full-pipeline dogfood (mesh drives real backlog) → M5 research domain →
M6 idea-watcher agent + web interview interface. Until a capability lands,
the single-device `hephaestus-automation-loop` remains the fallback driver;
both modes share labels and journal, so handoff is seamless.

## Consequences

**Positive:**

+ The PoC loop and the production mesh become the same system; no rewrite
  cliff between validation and operation.
+ Horizontal scale: stages parallelize across hosts while a host-wide
  semaphore or scheduler enforces the existing ≤3-heavy-agents-per-host
  budget across all local role consumers. Per-consumer `MaxAckPending` limits
  remain separate in-flight controls.
+ Provider and model choice become operational config, immune to account or
  vendor changes.
+ Separate canonical owners prevent instruction catalogs from silently
  becoming runtime queues or authority.
+ Contextually selected advise/learn paths let reusable knowledge flow through
  Mnemosyne without imposing a skill itinerary on every task.

**Negative:**

+ More moving parts than the conductor alternative: next-dispatch logic now
  executes inside N workers instead of one process; misrouting bugs surface
  as lost items until the seeder re-walks labels.
+ The merger duplicates some merge_wait verification logic; drift risk
  mitigated by extracting the shared proof module into the library both use.
+ Runtime-role changes still require coordinated Agamemnon + Myrmidons
  compatibility work when they affect the wire or routing contract.
+ Per-lane models complicate cost attribution and rate-limit budgeting.

**Neutral:**

+ The single-device loop stays supported indefinitely; it is the same library
  with a different executor binding.
+ The legacy harness remains live. Under this proposal it becomes eligible for
  retirement only after exact-pin mesh parity and real M4 dogfood evidence.

## Follow-up Notes (M0 implementation artifact)

[M0-2](https://github.com/HomericIntelligence/Odysseus/issues/466)
produced stage-chaining fields on top of the ADR-013 §3 pointer envelope and
published the versioned JSON Schema at
[`configs/schemas/dispatch-envelope.hi-v1.schema.json`](../../configs/schemas/dispatch-envelope.hi-v1.schema.json).
That implementation artifact does not ratify this Proposed ADR. The checked-in
schema is the current interface authority for consumers; new contract versions
get a new schema file rather than an in-place edit.

### Budget table → envelope counters

The `budgets` object in the `hi/v1` envelope carries exactly these counters.
A counter decrements only when a failure causes the work item to **re-enter the
same stage** (retry); fail-back exits (leaving the stage to another stage) and
terminal exits do not consume budget.

| Counter | Default | Owning stage | Consumption rule |
|---|---|---|---|
| `clone` | 2 | any (pre-stage) | Clone/prefetch retry of the same task |
| `plan` | 2 | planning | Retry within planning |
| `plan_review_iter` | 3 | plan_review | Retry within plan review |
| `plan_cycles` | 2 | planning ↔ plan_review | Full plan→review cycle re-entry |
| `implement` | 2 | implementation | Retry within implementation |
| `rebase_conflict` | 2 | implementation / merge | Rebase-conflict retry of same stage |
| `test_fix` | 1 | implementation | Test-fix loop within implementation |
| `pr_review_iter` | 3 | pr_review | Retry within PR review |
| `pr_review_hard` | 6 | pr_review | Hard ceiling across all PR-review retries |
| `merge` | 5 | merge | Merger retry budget (§3) |

### Exhaustion semantics

When a stage's counter reaches 0 on a retry-class failure, the worker stops
retrying and exits the item to **`state:skip`** — there is no cross-stage
escalation. Per the ADR-013 §2 ownership rule, only Hephaestus automation
writes `state:*` labels; mesh workers write them exclusively through the
existing Hephaestus mutation + readback path (§1). Merger exhaustion follows
the same path (§3: bounded by the merge budget of 5; exhaustion → `state:skip`).

## References

+ [ADR 013](013-hmas-mesh-wire-contracts.md) — wire contracts this ADR builds on
+ [ADR 016](016-split-hephaestus.md) — Hephaestus library vs Athena plugins split
+ [Proposed ADR 021](021-defer-multi-host-nomad-scheduling.md) — multi-host
  scheduling deferral
+ Odyssey retained instruction roles: `research/Odyssey/.claude/agents/`
+ Hephaestus automation architecture: `shared/Hephaestus/docs/architecture.md`
