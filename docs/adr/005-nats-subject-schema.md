# ADR 005: NATS Subject Schema

**Status:** Accepted

**Supersedes:** Subject examples in ADR 002

---

## Context

ADR 002 introduced NATS JetStream as the event bridge between ai-maestro webhooks and the rest of the HomericIntelligence ecosystem. The examples in ADR 002 used placeholder subjects (`maestro.agent.started`, `maestro.task.completed`) that were never implemented. The actual subject schema, designed and implemented in ProjectHermes, uses a hierarchical `hi.*` prefix with structured segments for routing and filtering.

This ADR documents the implemented subject schema as the authoritative reference.

## Decision

All NATS subjects in the HomericIntelligence ecosystem follow this schema:

### Agent Events

```
hi.agents.{host}.{name}.{verb}
```

- **host**: The ai-maestro hostId (e.g., `hermes`, `localhost`), slugified
- **name**: The agent name, slugified
- **verb**: One of `created`, `updated`, `deleted`

Examples:
- `hi.agents.hermes.code-reviewer.created`
- `hi.agents.localhost.my-agent.updated`

### Task Events

```
hi.tasks.{team_id}.{task_id}.{verb}
```

- **team_id**: The ai-maestro team ID
- **task_id**: The ai-maestro task ID
- **verb**: One of `updated`, `completed`, `failed`

Examples:
- `hi.tasks.team-42.task-7.updated`
- `hi.tasks.team-42.task-7.completed`

### JetStream Streams

| Stream Name | Subjects | Retention |
|---|---|---|
| `homeric-agents` | `hi.agents.>` | Limits-based (default) |
| `homeric-tasks` | `hi.tasks.>` | Limits-based (default) |

Streams are created by ProjectHermes on startup if they do not already exist.

### Durable Consumers

| Consumer | Stream | Filter Subject | Service |
|---|---|---|---|
| `keystone-dag` | `homeric-tasks` | `hi.tasks.>` | ProjectKeystone |

Additional durable consumers should be registered here as services are added.

### Slugification

All dynamic segments (host, name) are slugified by ProjectHermes: spaces become hyphens, dots become hyphens, all lowercase. This ensures subjects are valid NATS tokens.

## Consequences

- All subscribers must use the `hi.*` prefix, not the `maestro.*` prefix shown in ADR 002 examples.
- Subscribers wanting all events for a category should use `>` wildcard: `hi.agents.>`, `hi.tasks.>`.
- Subscribers wanting events for a specific entity can filter: `hi.tasks.team-42.>`.
- New event verbs can be added without changing stream configuration.
