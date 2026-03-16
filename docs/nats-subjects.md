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

```
pending -> in_progress -> review -> completed
                                 -> failed
```

Keystone advances DAGs when it sees `completed` (either as the subject verb or in the payload status field).
