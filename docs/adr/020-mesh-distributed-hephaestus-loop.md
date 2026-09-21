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

Proposed ADR-013 targets role-addressed dispatch
(`hi.myrmidon.{domain}.{role}.task.{task_id}`), JetStream lease semantics,
state-fact subjects, epic conventions, and a one-to-one mapping between
Agamemnon's HMAS task states and the Hephaestus labels. Those targets are not
binding or deployed merely because component source contains adjacent routes or
schemas. The provisioning side is scaffolded but idle: AchaeanFleet ships an
`achaean-mesh` vessel expecting a `Hephaestus[mesh]` extra and a
`hephaestus-mesh-worker` entry point that do not exist yet; the Myrmidons repo
already carries mesh pool manifests for `pipeline.chief-architect`,
`pipeline.task-agent`, and `research.chief-architect`.

Meanwhile Hephaestus' runtime abstraction supports multiple explicit adapters
(`AgentName = Literal["claude", "codex", "pi", "opencode"]`). The mesh must
therefore preserve the selected per-invocation provider/model and remain
provider-neutral; mutable personal account state is not an architectural
premise and selects no default.

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
| Planning | `chief-architect` | Planning | request relevant advice; unavailable/stale advice is non-vetoing |
| Plan review | `plan-reviewer` (new) | Review | read-only scope |
| Implementation | `task-agent` | Implementation | writer scope |
| PR review | `pr-reviewer` (new) | Review | sole writer of `implementation-go/-no-go` |
| Merge | `merger` (new) | Mechanical | see §3 |
| Learn | aux queue post-merge | Mechanical→Review | separately authorized; otherwise no-write SKIP |

### 3. Merger agent

A dedicated mechanical worker subscribes to impl-go review outcomes. On each
packet it first treats the NATS envelope as a wake-up fact, not remote-write
authority. Before any label, comment, or remediation write, it acquires and
reads back the exact authenticated manifest/task/lease for the claimed
repository, issue, attempt, and merge stage, then binds that claim to the
current GitHub object and operation generation. Only a schema or identity fact
proved definitively malformed, replayed, foreign-repo, wrong-task, wrong-stage,
expired, or unclaimed receives `AckTerm`, and only after a durable idempotent
invalid-packet receipt keyed by stream, consumer, and sequence. An unavailable,
ambiguous, or lost manifest/task/lease read preserves the delivery for bounded
retry and reconciliation and performs no GitHub mutation. Only a valid claimed
invocation may continue.

For that invocation it requires one authentic terminal Athena review carrier
for the exact source head and exact base tip. The carrier must bind its publication anchor,
ordered reviewer/author exchange, expected actor identity, terminal GO state,
and zero pending review events. Independently, the merger requires zero open
review threads, exclusive-label consistency, and green required checks from the
expected applications on that same head. A spoofed, stale, edited, foreign,
wrong-actor, incomplete, or conflicting carrier has no authority.

After those checks, a trusted host adapter compare-and-swaps one immutable,
single-use `merge_authorized` receipt containing the complete validated
snapshot and carrier hash. GitHub comments, labels, and threads are mutable
pre-admission evidence; they are not falsely claimed to be atomic predicates
after that receipt is consumed, and a second review event for the same receipt
cannot create another effect. Source-head or base-tip movement always cancels
the receipt. If policy requires a later mutable event to revoke an admitted
merge, a repository-enforced trusted gate that atomically blocks that event is
required; without one the automated path stops for human action.

The merger never enables standing ordinary auto-merge. It admits only the
receipt's exact source-head/base-tip pair to a merge queue or merge group with
an atomic expected-source and expected-base predicate; required checks run on
the resulting merge candidate. A repository without that primitive stops for
human action. Post-merge readback must match the admitted pair, merge result,
commit, parents, tree, and pull request. Any pre-admission failure for an
authenticated, currently claimed invocation is classified before mutation.
Only a definitive, bound review or check failure may write
`state:implementation-no-go` and publish remediation. An unavailable,
ambiguous, pending, or lost-response review, check, receipt-ledger, forge, or
queue state preserves the current label and is durably retried or reconciled;
budget exhaustion ends in a truthful blocked/`state:skip` receipt without
inventing an implementation verdict. The merge retry budget remains five. The
merger runs with least-scoped credentials in its own vessel.

The existing `hi/v1` `reason` and `evidence` fields remain wire-compatible, but
their bytes are size-bounded, schema-validated untrusted payload. They cannot
authorize a state transition and use ADR-022's collision-safe
`hi.prompt-payload/v1` representation in every receiving prompt; a raw textual
fence is not a fallback. Where possible they contain immutable evidence
references and digests rather than copied prose.

Behavior tests must prove that replayed packets and foreign repository, task,
attempt, stage, lease, or generation claims cannot mutate forge state, while an
exact claimed invocation can write one bounded remediation result. Hostile and
oversized reason/evidence values must be rejected or fenced without becoming
instructions or remote-write authority.

### 4. Provider-neutral lanes preserve deployed defaults

The agent backend is per-manifest configuration resolved through the
existing Hephaestus runtime abstraction. The exact current manifest fields are
the authority for each program, provider, model, role, and lane. This ADR does
not select an operator provider, add a lane-specific pin, or change any default.
Planning, Implementation, Review, and Mechanical lanes may resolve different
models only when a separately reviewed manifest change explicitly authorizes
that change and preserves compatibility; no model or provider is inferred from
role prose or hard-coded in the loop.

### 5. Retain the bounded Odyssey role surface; do not import its old hierarchy

The earlier Odyssey 6-level / 30-agent hierarchy is not a canonical import
source. Odyssey retains and modernizes only `chief-architect`,
`implementation-engineer`, `ci-failure-analyzer`,
`code-review-orchestrator`, `general-review-specialist`,
`mojo-language-review-specialist`, `numerical-stability-specialist`,
`security-review-specialist`, and `test-review-specialist`. Every consumer of
an overlapping role migrates before that role is removed. The runtime queue
roles in section 2 are explicit stage identifiers, not evidence of an imported
level hierarchy or model tier. This ADR adds no hierarchy-sync gate, no fixed
delegation graph, and no Agamemnon level-extension requirement.

### 6. GitHub remains the task-content source; packets stay pointers

Every milestone is tracked as a **GitHub epic with child issues in the repo
that owns most of the milestone's work** (per-repo epics). Every child issue
is exactly one dispatchable task. NATS packets carry only the ADR-013 pointer
envelope (`repo`, `issue`, `epic_key`, `branch`, `attempt`, budget counters);
workers read the full task description from GitHub at claim time. GitHub labels
hold the workflow journal, while Agamemnon's store owns the task tree and its
service state. Neither is described as the other's backing store. NATS carries
pointer facts, never authority.

### 7. Telemachy registers requirements; a planner agent plans the epic

Telemachy does not plan. Milestone workflow YAMLs encode **requirements,
goals, invariants, and research context**, then direct Telemachy's executor
to launch a planner sub-agent for the epic decomposition. That planner runs
under the **athena:advise** skill, using relevant available Mnemosyne context
without treating stale or unavailable guidance as a veto on otherwise
authorized work. It produces the child-issue breakdown, and Telemachy registers
the epic + children (`state:needs-plan`) and publishes
`hi.pipeline.epic.{key}.registered`.

### 8. Load relevant advice; authorize learning separately

Every planning surface (epic planning and per-issue planning) requests relevant
Mnemosyne context through `athena:advise` before generating plans. Missing,
stale, or unverifiable guidance limits the advice and is recorded, but does not
stop otherwise authorized primary work unless a concrete protected boundary is
unresolved.

Learning is a separate cross-repository write, not authority inherited from a
code merge. A post-merge `athena:learn` run may create a Mnemosyne branch or PR
only when the current user or a manifest-bound operation explicitly authorizes
that repository, lesson scope, and remote effect. Otherwise the worker records
a no-write SKIP and completes the primary task without silently claiming that a
lesson was published.

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
- Provider and model choice remains explicit manifest configuration without
  this ADR changing a deployed default.
- The bounded retained Odyssey role set removes the old 30-role import as a
  source of hierarchy and model-tier drift.
- Contextual advice is requested for planning, while separately authorized
  learning can preserve reusable evidence without making a cross-repository
  write an implicit consequence of every task.

**Negative:**
- More moving parts than the conductor alternative: next-dispatch logic now
  executes inside N workers instead of one process; misrouting bugs surface
  as lost items until the seeder re-walks labels.
- The merger needs a trusted one-shot review-admission receipt and an atomic
  source-head/base-tip queue primitive. Repositories without that capability
  require human merge rather than a weaker auto-merge fallback.
- Retiring overlapping Odyssey roles requires consumer migration before
  deletion, while runtime stage-role identifiers remain separately explicit.

**Neutral:**
- The single-device loop stays supported indefinitely; it is the same library
  with a different executor binding.
- Legacy `e2e/claude-myrmidon.py` subjects remain deprecated; the new worker
  is ADR-013-native and the old harness migrates or retires at M4.

## Implemented `hi/v1` Compatibility Artifact

[M0-2](https://github.com/HomericIntelligence/Odysseus/issues/466) and commit
[`09d729cff7d0221cc9713e77f85163e2181eac3c`](https://github.com/HomericIntelligence/Odysseus/commit/09d729cff7d0221cc9713e77f85163e2181eac3c)
added the checked-in versioned JSON Schema at
[`configs/schemas/dispatch-envelope.hi-v1.schema.json`](../../configs/schemas/dispatch-envelope.hi-v1.schema.json)
and its executable
[`tests/test-dispatch-envelope-schema.sh`](../../tests/test-dispatch-envelope-schema.sh)
validation. At this repository binding, that schema is current implemented
compatibility evidence: implementations claiming `hi/v1` compatibility must
conform to the checked-in artifact, and an incompatible envelope shape requires
a new schema version rather than an in-place reinterpretation.

That implementation did not ratify or accept this Proposed ADR, make its
remaining M1–M6 design binding, or prove distributed runtime behavior. Formal
acceptance and behavior evidence remain separate requirements.

### Proposed budget semantics represented by the schema

The checked-in schema requires exactly these `budgets` counter names, validates
their values as nonnegative integers, and carries the listed defaults as JSON
Schema annotations. JSON Schema validation neither inserts those defaults nor
enforces when a worker decrements a counter. The table below records this
proposal's intended runtime interpretation: a counter would decrement only
when a failure causes the item to re-enter the same stage; fail-back and
terminal exits would not consume budget. Runtime tests are required before
claiming that behavior.

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

### Proposed exhaustion semantics

If this ADR is accepted and implemented, a retry-class failure with its stage
counter at zero would stop retrying and exit the item to `state:skip`, without
cross-stage escalation. Under the Proposed ADR-013 ownership target, mesh
workers would write `state:*` only through the Hephaestus mutation-and-readback
path described in section 1. Merger exhaustion would follow the same proposed
path. The current schema can validate a zero counter; it cannot prove or enforce
any of these transitions.

## References

- [Proposed ADR 013](013-hmas-mesh-wire-contracts.md) — wire contracts this
  proposal builds on
- [Accepted ADR 016](016-split-hephaestus.md) — Hephaestus library vs Athena
  plugins split
- [Proposed ADR 023](023-defer-multi-host-nomad-scheduling.md) — multi-host
  scheduling deferral proposal
- Historical Odyssey hierarchy (not an import source):
  `research/Odyssey/agents/hierarchy.md`
- Hephaestus automation architecture: `shared/Hephaestus/docs/architecture.md`
