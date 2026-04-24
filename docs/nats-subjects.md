# NATS Subject Schema

Central reference for the HomericIntelligence NATS event bus. See [ADR 005](adr/005-nats-subject-schema.md) for decision context.

## Subject Patterns

| Pattern | Published By | Consumed By | Description |
|---|---|---|---|
| `hi.agents.{host}.{name}.created` | Hermes | Argus, Telemachy | Agent registered |
| `hi.agents.{host}.{name}.updated` | Hermes | Argus | Agent state changed |
| `hi.agents.{host}.{name}.deleted` | Hermes | Argus, Telemachy | Agent removed |
| `hi.tasks.{team_id}.{task_id}.updated` | Hermes | Keystone, Argus | Task status changed |
| `hi.tasks.{team_id}.{task_id}.completed` | Hermes | Keystone, Argus | Task completed |
| `hi.tasks.{team_id}.{task_id}.failed` | Hermes | Keystone, Argus | Task failed |

## Message Payload Schema

All NATS messages follow a standard envelope structure:

```json
{
  "event": "task.completed",
  "data": { /* event-specific fields */ },
  "timestamp": "2026-04-23T15:30:00Z"
}
```

The `timestamp` field is ISO-8601 formatted UTC. The `data` object contains event-specific fields; **note that `status` is nested inside `data`, not at the top level**.

### Event-Specific Data Fields

**task.created**
```json
{
  "event": "task.created",
  "data": {
    "task_id": "task-uuid",
    "team_id": "team-id",
    "title": "Task title",
    "description": "Task description",
    "status": "backlog",
    "assigned_to": null
  },
  "timestamp": "2026-04-23T15:30:00Z"
}
```

**task.updated**
```json
{
  "event": "task.updated",
  "data": {
    "task_id": "task-uuid",
    "team_id": "team-id",
    "status": "in_progress",
    "assigned_to": "agent-id",
    "changes": ["status", "assigned_to"]
  },
  "timestamp": "2026-04-23T15:30:00Z"
}
```

**task.completed**
```json
{
  "event": "task.completed",
  "data": {
    "task_id": "task-uuid",
    "team_id": "team-id",
    "status": "completed",
    "result": "Task completed successfully",
    "completed_at": "2026-04-23T15:35:00Z"
  },
  "timestamp": "2026-04-23T15:35:00Z"
}
```

**task.failed**
```json
{
  "event": "task.failed",
  "data": {
    "task_id": "task-uuid",
    "team_id": "team-id",
    "status": "failed",
    "error": "Task execution failed",
    "error_code": "EXECUTION_ERROR",
    "failed_at": "2026-04-23T15:35:00Z"
  },
  "timestamp": "2026-04-23T15:35:00Z"
}
```

**agent.created**
```json
{
  "event": "agent.created",
  "data": {
    "host": "hostname",
    "name": "agent-name",
    "type": "agent-type",
    "capabilities": ["cap1", "cap2"]
  },
  "timestamp": "2026-04-23T15:30:00Z"
}
```

**agent.removed**
```json
{
  "event": "agent.removed",
  "data": {
    "host": "hostname",
    "name": "agent-name",
    "removed_at": "2026-04-23T15:35:00Z"
  },
  "timestamp": "2026-04-23T15:35:00Z"
}
```

## JetStream Streams

| Stream | Subjects | Created By |
|---|---|---|
| `homeric-agents` | `hi.agents.>` | Hermes (on startup) |
| `homeric-tasks` | `hi.tasks.>` | Hermes (on startup) |

## Durable Consumers

| Consumer Name | Stream | Service | Purpose |
|---|---|---|---|
| `keystone-dag` | `homeric-tasks` | ProjectKeystone | DAG advancement on task completion |

## Subscription Examples

```python
# Subscribe to all task events (wildcard)
await js.subscribe("hi.tasks.>", durable="my-consumer", cb=handler)

# Subscribe to events for a specific team
await js.subscribe("hi.tasks.team-42.>", cb=handler)

# Subscribe to only completions across all teams
await js.subscribe("hi.tasks.*.*.completed", cb=handler)
```

## Task Status Lifecycle

All tasks follow a canonical lifecycle with eight possible statuses:

| Status | Category | Description | NATS Event |
|---|---|---|---|
| `backlog` | Initial | Task created but not yet scheduled | task.created |
| `pending` | Active | Task scheduled and awaiting assignment | (task.updated) |
| `in_progress` | Active | Task assigned and execution underway | (task.updated) |
| `review` | Active | Task execution complete, awaiting human review | (task.updated) |
| `completed` | Terminal (success) | Task completed successfully | **task.completed** |
| `failed` | Terminal (failure) | Task execution failed | **task.failed** |
| `error` | Terminal (system error) | Task encountered unrecoverable system error | (task.failed) |
| `cancelled` | Terminal (manual) | Task manually cancelled before completion | (task.updated) |

**Transition Rules:**
- Initial state: `backlog`
- Active states flow: `backlog` → `pending` → `in_progress` → (`review`) → terminal
- Terminal states are final: no transitions out
- Only `completed` and `failed` trigger dedicated NATS events; other transitions use `task.updated`

**Canonical Source of Truth:**
This lifecycle is the authoritative specification for the HomericIntelligence ecosystem. ProjectKeystone, ProjectTelemachy, ProjectAgamemnon, and ProjectHermes must conform to these statuses and transition rules. Keystone advances DAGs when tasks reach terminal states (`completed`, `failed`, `error`, `cancelled`).
