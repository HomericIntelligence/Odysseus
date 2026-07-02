# ADR 013: HMAS Mesh Wire Contracts — Role-Addressed Dispatch, State Events, and Task Sizing

**Status:** Proposed

**Extends:** [ADR 005](005-nats-subject-schema.md)

---

## Context

The HMAS primitives exist in isolation — Agamemnon's TaskStateMachine and
`/v1/briefs` ingestion, Hephaestus' planner/implementer/reviewer product layer
and `state:*` labels, Nestor's research intake, Telemachy's workflow engine —
but the connective wire contracts between them were never defined:

- Agamemnon dispatches on two-token `hi.myrmidon.{type}.{task_id}` subjects
  that no worker consumes, and `hi.myrmidon.*` is absent from ADR-005 entirely
  (the Odysseus console removed its subscription for exactly this reason,
  issue #211).
- Agamemnon subscribes only to `hi.tasks.*.*.completed`; workers have no way
  to signal start or failure, so assignment is never recorded.
- There is no defined interview channel, no epic-registration trigger, no
  research dispatch queue, and no lease/heartbeat/idempotency contract for
  workers.

This ADR defines the authoritative wire contracts for the HMAS mesh pipeline:
subject grammar, JetStream consumer configuration, payload envelopes, task
sizing and overrun re-adjustment, event-vs-store ownership, the interview
relay, and epic conventions.

## Decision

### 1. Role-addressed dispatch subjects (pull work queues)

```
hi.myrmidon.{domain}.{role}.task.{task_id}
```

- **domain** ∈ `research`, `pipeline` (extensible: any slugified domain).
- **role** is an HMAS role NAME, never a level number: `chief-architect`,
  `component-lead`, `module-lead`, `task-agent`, and deeper roles as the
  hierarchy grows (`specialist`, `engineer`, `junior`, …).
- The literal `task` token separates new subjects from legacy two-token
  publishes so new consumers never receive legacy messages.

**Role taxonomy.** Myrmidon roles ARE the HMAS agentic roles at every level of
the hierarchy, crossed with domain — a `research.chief-architect` myrmidon and
a `pipeline.chief-architect` myrmidon are distinct pool queues. The hierarchy
is extensible beyond four levels: ProjectAgamemnon's AGENTS.md 4-level
instantiation (L0 chief-architect → L3 task-agent) and ProjectOdyssey's
`agents/hierarchy.md` 6-level/30-agent instantiation are both valid. Model
tiers map to role depth: opus for architect-level roles, sonnet for
mid-hierarchy and task agents, **haiku for junior roles**. The wire contract
never encodes the level number — only the role name — so deeper hierarchies
require no subject changes.

**Consumers.** One durable pull consumer per (domain, role):

| Setting | Value |
|---|---|
| Durable name | `myrmidon-{domain}-{role}` |
| Stream | `homeric-myrmidon` |
| Filter subject | `hi.myrmidon.{domain}.{role}.task.>` |
| Ack policy | `AckExplicit` |
| AckWait | 900 s (15 min) |
| MaxDeliver | 3 |
| MaxAckPending | pool concurrency cap (initial: 3 = host heavy-agent budget) |

Each worker fetches one message at a time (`fetch(1)`) — one task per
myrmidon. Workers heartbeat with `msg.in_progress()` every 5 minutes; three
missed heartbeats (AckWait expiry) mean the worker is dead and the task is
redelivered. Ack happens only after completion.

**Migration.** Legacy two-token subjects (`hi.myrmidon.{type}.{task_id}`) are
dual-published for one release, then removed. Operators must purge the stale
`homeric-myrmidon` backlog before bringing up role-addressed consumers.

### 2. Task state events (facts, fan-out)

```
hi.tasks.{team_id}.{task_id}.{verb}    verb ∈ started | updated | completed | failed
```

This adds the `started` verb to ADR-005's list. Workers publish `started`
immediately after claiming (payload carries `agent_id` and `exec_host` — this
IS the assignment record; assignment happens at claim, not at dispatch).

**Ownership rule (normative):**

- **Workers publish events.** They never write Agamemnon's store directly.
- **Only Agamemnon writes its backing store** (GitHub Issues/Projects).
- **Only Hephaestus automation writes `state:*` labels** (`state:needs-plan`,
  `state:plan-go/-no-go`, `state:implementation-go/-no-go`, `state:skip`).

Code truth lives in the git branch; state truth lives in GitHub labels plus
Agamemnon's store. NATS messages are pointers and facts, never the state
itself.

### 3. Payload envelope

Every payload is JSON with envelope fields:

```json
{"schema": "hi/v1", "ts": "<ISO-8601>", "msg_id": "<uuid>"}
```

Dispatch payloads carry pointers, not content: `task_id`, `team_id`, `role`,
`domain`, `repo`, `issue`, `epic {repo, issue, key}`, `branch`,
`base_branch`, `blocked_by[]`, `intake_id`, `attempt`. Research dispatch
additionally carries `idea`/`context` inline (no issue exists yet). State
events add `agent_id`, `exec_host`, `pr {number, url, merged}`,
`error {kind, message, retryable}`.

### 4. Task sizing and overrun re-adjustment

- **Planner acceptance criterion:** leaf tasks are sized to ≲1 hour of active
  work.
- **No hard time limit.** A task exceeding ~1 hour of ACTIVE work triggers
  re-adjustment, not failure: based on its current state and plan it is broken
  into multiple smaller tasks — progress preserved, remainder re-planned.
- **Worker overrun handler:** at ~1 h active the worker
  1. checkpoints — commits and pushes its branch, posts a progress comment
     with marker `<!-- hi:checkpoint {task_id} -->`;
  2. derives the remainder from its current plan/state;
  3. registers the remainder as sub-tasks via Agamemnon REST
     (`POST /v1/tasks/:id/split`) with `blocked_by` chaining and the
     checkpoint branch as `base_branch`;
  4. publishes `completed` for the current task (it becomes the first slice
     of the split) and acks.
- **Leases detect death, not length.** The 5-minute heartbeat keeps a healthy
  long-running task alive indefinitely; AckWait expiry only fires on worker
  death. Sizing overruns are handled by the split mechanism above.
- **Idempotency preamble.** On redelivery (attempt > 1) the worker first
  checks for an existing branch, PR, labels, and Agamemnon task state, then
  resumes from the last checkpoint or no-ops. Workers post a GitHub progress
  comment at every major step or at least hourly — this is the resume anchor.
- **Wall-clock-long work is event-driven, never held.** A multi-epic
  orchestration node sleeps inside Agamemnon between child completions
  (`blocked_by` graph); each child completion wakes it and dispatches a
  bounded burst of newly unblocked work to the role queues. A worker never
  holds a lease while waiting on another task.

### 5. Interview relay

```
hi.pipeline.interview.{intake_id}.question.{q_id}   worker → console
hi.pipeline.interview.{intake_id}.answer.{q_id}     console → worker
```

The interviewing worker is a research-pool myrmidon (LLM work never runs
inside the C++ services — Nestor stays a thin intake/status/dispatch service,
the same principle as Agamemnon).

Fallback ladder:

1. Question published on NATS; console prompts the user live.
2. Unanswered after 15 min → worker posts the question to the intake issue
   with marker `<!-- hi:question {intake_id}/{q_id} -->` and polls comments
   every 60 s for up to 24 h.
3. A late console answer wins over a pending GitHub poll. GitHub answers are
   re-published on the answer subject with `"channel": "github"` so NATS
   carries the full transcript.
4. Both channels time out → the worker proceeds with stated assumptions and
   re-publishes the question with `"status": "assumed"`.

All Q&A is mirrored to the intake issue for audit.

### 6. Epic registration trigger

```
hi.pipeline.epic.{epic_key}.registered      epic_key = {repo_slug}-{issue_number}
```

Telemachy creates the epic issue (label `agamemnon-epic`) and its child
issues, then publishes this subject. Agamemnon consumes it with durable
`agamemnon-epics` and submits the HMAS root (Pending → Decomposing).

**Epic body convention** (parseable task list, precedent:
ProjectOdyssey `scripts/implement_issues.py`):

```markdown
- [ ] #123 (depends on: #456)
- [ ] #124
```

Child issues carry label `state:needs-plan` at creation.

### 7. Research dispatch

`POST /v1/research` on Nestor publishes
`hi.myrmidon.research.chief-architect.task.{research_id}` (the research pool
queue). `hi.research.{id}` is retained as a status/compat subject; externally
published completion status on `hi.research.>` closes Nestor's store item.

### 8. Logs

```
hi.logs.myrmidon.{domain}.{role}.{agent_id}
```

Every payload carries `exec_host`.

### 9. Streams

| Stream | Subjects | Notes |
|---|---|---|
| `homeric-myrmidon` | `hi.myrmidon.>` | exists; work queues |
| `homeric-tasks` | `hi.tasks.>` | exists; state events |
| `homeric-agents` | `hi.agents.>` | exists |
| `homeric-logs` | `hi.logs.>` | exists |
| `homeric-pipeline` | `hi.pipeline.>` | made authoritative; limits-based retention (multiple readers) |

### 10. State machine mapping

One row per pipeline phase — owner / storage / trigger:

| Phase | HMAS state | Trigger | Storage |
|---|---|---|---|
| Intake | — | console `submit` → `POST /v1/research` | Nestor store (pending); worker creates intake issue (label `intake`) |
| Research + interview | flat task InProgress | worker `started` event | intake issue transcript |
| Epic registered | Pending → Decomposing | `hi.pipeline.epic.*.registered` → Submit | epic + child issues (`state:needs-plan`) |
| Decomposing | Decomposing | planner burst → `pipeline.chief-architect` queue | — |
| Planned / Delegated | Decomposing → Delegated | planner `completed` → brief ingested (`POST /v1/briefs`, L0–L3 tree, child-issue refs on L3 nodes) | Agamemnon store; `state:plan-go/-no-go` per child issue |
| Executing | Delegated → InProgress | worker `started` (records `agent_id`/`exec_host`) | branch + progress comments |
| Review gate | InProgress | PR review inside worker | `state:implementation-go/-no-go` on PR |
| Done | InProgress → Completed | worker `completed`; PR auto-merge (squash) armed only after `state:implementation-go`; body `Closes #N`; signed commits | merged PR |
| Split (overrun) | Completed + new Pending children | `POST /v1/tasks/:id/split` then normal `completed` | checkpoint branch is children's `base_branch` |
| Failed / Escalated | InProgress → Failed / Escalated | `failed` event → Fail; MaxDeliver exhaustion → Escalated (bottom-up delegation) | `state:skip` on exhaustion |
| Blocked / parent nodes | Delegated (parked) | child completion → `delegate_unblocked_children` → next burst | Agamemnon `blocked_by` graph — never held by a worker |

## Consequences

**Positive:**

- Every existing HMAS primitive (state machine, briefs, labels, advise/learn)
  is connected by an explicit, versioned wire contract.
- Role-addressed queues make the worker pool horizontally scalable per
  (domain, role) without touching the subject grammar, including hierarchy
  levels and model tiers that do not exist yet.
- Leases + idempotency preamble give at-least-once execution with safe resume
  after worker death; the split mechanism keeps task sizing honest without
  hard-killing long work.
- The console's `hi.myrmidon.>` subscription can return (issue #211 is
  resolved by this ADR documenting the namespace).

**Negative:**

- Dual-publish migration window doubles dispatch traffic for one release.
  Mitigation: the `.task.` token isolates new consumers; legacy publish is
  removed after one release.
- AckWait=900 s means a dead worker delays redelivery by up to 15 minutes.
  Mitigation: acceptable for ≲1 h tasks; heartbeat interval (5 min) is a
  worker constant that can be tightened without a consumer change.
- The interview GitHub fallback polls (60 s); webhook wiring is deferred.

**Neutral:**

- ADR-005's verb list grows by `started`; existing subscribers using `>`
  wildcards are unaffected.
- The `homeric-pipeline` stream becomes authoritative for `hi.pipeline.>`;
  consumers that used core NATS keep working (stream capture is additive).

## References

- [ADR 002](002-nats-event-bridge.md) — NATS event bridge
- [ADR 005](005-nats-subject-schema.md) — subject schema this ADR extends
- [ADR 008](008-nats-tls-encryption.md) / [ADR 009](009-nats-authentication.md)
  / [ADR 010](010-nats-mtls-subject-scoped-auth.md) — transport security for
  all publishers/consumers introduced here
- [ADR 011](011-extract-python-orchestration-to-agamemnon.md) — Python
  orchestration ownership
- ProjectAgamemnon `AGENTS.md` — 4-level HMAS instantiation
- ProjectOdyssey `agents/hierarchy.md` — 6-level/30-agent instantiation
- Issue [#211](https://github.com/HomericIntelligence/Odysseus/issues/211) —
  console `hi.myrmidon.>` subscription removal
