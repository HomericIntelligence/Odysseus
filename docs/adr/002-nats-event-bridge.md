# ADR 002: Use NATS JetStream as Event Bridge for ai-maestro Webhooks

**Status:** Accepted

---

## Context

ai-maestro emits outbound webhooks on agent lifecycle events (agent created,
started, stopped, task completed, etc.). These webhooks are HTTP POST requests
sent to a single configured endpoint. They are fire-and-forget: if the
receiving endpoint is down, the event is lost. There is no replay mechanism and
no fan-out — a single event can only be delivered to one endpoint at a time.

As the HomericIntelligence ecosystem grows, multiple services need to react to
the same ai-maestro events:
- ProjectArgus needs task-completion events for SLA metrics.
- ProjectTelemachy needs agent-started events to advance workflow state
  machines.
- ProjectScylla needs agent-stopped events to detect unexpected failures.
- Future consumers will emerge as the ecosystem expands.

Changing ai-maestro to support multiple webhook targets or replay is not an
option (ADR 004: extend, do not replace).

ai-maestro already provides AMP (Agent Message Protocol) for point-to-point
messaging between agents. AMP is not appropriate for this use case: it requires
a sender and receiver to be registered agents, it is synchronous, and it does
not provide durable replay.

## Decision

We introduce **ProjectHermes** as a NATS JetStream event bridge between
ai-maestro webhooks and all other consumers.

The architecture is:

1. ai-maestro is configured with a single webhook endpoint pointing to
   ProjectHermes.
2. ProjectHermes receives every webhook, validates it, and publishes it to a
   NATS JetStream subject (e.g., `maestro.agent.started`,
   `maestro.task.completed`).
3. Any service that needs ai-maestro events subscribes to the relevant NATS
   subject. Subscriptions are durable, so offline consumers catch up on
   reconnect.
4. JetStream stores messages for a configurable retention window, enabling
   replay of missed events after a consumer restart.

**NATS JetStream** is chosen as the messaging layer because:
- Single binary, no external dependencies, low memory footprint.
- Sub-millisecond publish latency.
- Durable consumers with at-least-once delivery guarantees.
- Replay from sequence number or timestamp.
- Leaf node topology allows multi-host deployments without a full cluster.

**AMP is not replaced.** AMP stays as the point-to-point channel for
agent-to-agent communication as ai-maestro intends. NATS JetStream is an
addition for infrastructure-level event fan-out.

## Consequences

**Positive:**
- Any number of consumers can subscribe to ai-maestro events without modifying
  ai-maestro.
- Guaranteed delivery: offline consumers catch up on reconnect via durable
  subscriptions.
- Replay: JetStream retention allows re-processing of past events for debugging
  or new consumer onboarding.
- Sub-millisecond publish latency from ProjectHermes to subscribers.
- Clean separation: ai-maestro knows about one webhook target; NATS handles
  fan-out.

**Negative:**
- NATS adds an infrastructure component that must be deployed and monitored
  (see `configs/nats/server.conf`).
- ProjectHermes is a new service that must be kept running for event delivery.
- At-least-once delivery means consumers must be idempotent.

**Neutral:**
- AMP remains the correct channel for agent-to-agent messages. Teams should not
  use NATS for agent messaging; NATS is for infrastructure events only.
- NATS JetStream configuration is in `configs/nats/` in this repo.
