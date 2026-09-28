# NATS Interface Routes

This page routes readers to the current wire authorities. It is not a copied
schema or lifecycle specification. [Accepted ADR-005](adr/005-nats-subject-schema.md)
records the original subject decision; later Proposed ADRs describe possible
evolution but are not deployment evidence.

## Current authorities

- Agamemnon's pinned `docs/api/openapi.yaml` owns the subjects emitted by its
  task and HMAS APIs and the task-status enum accepted by those APIs.
- Hermes's pinned `openapi.json`, `src/hermes/models.py`, and
  `src/hermes/publisher.py` own accepted webhook events, their NATS routing,
  and the webhook-event envelope.
- [`configs/schemas/dispatch-envelope.hi-v1.schema.json`](../configs/schemas/dispatch-envelope.hi-v1.schema.json)
  owns the versioned `hi/v1` pipeline dispatch packet.
- [`configs/nats/server.conf`](../configs/nats/server.conf) and
  [`configs/nats/leaf.conf`](../configs/nats/leaf.conf) own the checked-in
  broker permissions and stream storage configuration. They do not prove live
  deployment state.

Always bind the exact component gitlink before relying on an interface. If a
root summary and the component source disagree, the component interface wins
and this page must be corrected.

## Exact-pin routing summary

At the component pins recorded by this Odysseus revision, Agamemnon documents:

| Operation | Subject |
|---|---|
| Create task | `hi.tasks.created` |
| Dispatch created task | `hi.myrmidon.{type}.{task_id}` |
| Update task through PUT or PATCH | `hi.tasks.{team_id}.{task_id}.updated` |
| Record completed-task log | `hi.logs.agamemnon.task_completed` |

Agamemnon's ordinary task status enum is exactly `pending`, `running`,
`completed`, `failed`, and `blocked`. Its HMAS state machine is a separate
interface and must not be collapsed into that enum. Both PUT and PATCH task
updates use merge semantics at this pin.

Hermes accepts only these routed webhook event names:

| Event | Subject shape |
|---|---|
| `agent.created` | `hi.agents.{host}.{name}.created` |
| `agent.updated` | `hi.agents.{host}.{name}.updated` |
| `agent.deleted` | `hi.agents.{host}.{name}.deleted` |
| `task.updated` | `hi.tasks.{team_id}.{task_id}.updated` |
| `task.completed` | `hi.tasks.{team_id}.{task_id}.completed` |
| `task.failed` | `hi.tasks.{team_id}.{task_id}.failed` |

`task.created` is not a Hermes accepted event at this pin; Agamemnon owns its
creation subject. Unknown Hermes event types follow Hermes's configured
dead-letter behavior rather than being silently treated as one of the events
above.

The Hermes-published JSON envelope contains `schema_version`, `event`, `data`,
`timestamp`, and `request_id`. Event-specific fields remain inside `data`.
Consult the pinned Hermes models and OpenAPI document for exact validation and
response shapes instead of copying examples from this page.

## Streams and consumers

The pinned Hermes publisher ensures `homeric-agents` for `hi.agents.>`,
`homeric-tasks` for `hi.tasks.>`, and its configured dead-letter stream when it
connects successfully. A stream declaration in source is not proof that a
stream exists or is healthy. Query the authorized live system identity for
that evidence.

Consumer names, filters, acknowledgment policy, and replay behavior belong to
the owning component and live server state. Do not infer a durable consumer or
advance it from this routing page.

## Proposed pipeline subjects

Subjects under `hi.myrmidon.pipeline.*`, role-addressed queues, research
interview relays, and the distributed automation loop are described by
Proposed ADRs 013 and 020 and their checked-in workflow artifacts. Treat those
descriptions as target architecture unless an exact runtime source and live
readback prove a particular path is implemented.
