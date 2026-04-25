# ADR 006: Decouple HomericIntelligence from ai-maestro

**Status:** Accepted

---

## Context

ADR-004 established a policy of extending ai-maestro via its REST APIs rather
than replacing its capabilities. This was sound when ai-maestro was the
ecosystem's core platform and we needed strict architectural discipline to
prevent duplicate state.

However, the HomericIntelligence ecosystem has evolved. We are now building our
own native components that provide the capabilities ai-maestro once centralized:

- **ProjectAgamemnon** (C++20): Planning, coordination, state machines, and
  HMAS orchestration with GitHub Issues as the backing store.
- **ProjectNestor** (C++20): Research, ideation, and search. Hands off
  researched briefs to Agamemnon.
- **ProjectCharybdis** (C++20): Chaos testing via Agamemnon `/v1/chaos/*`
  endpoints.
- **ProjectKeystone**: Invisible transport layer (BlazingMQ + NATS JetStream).
  All communication flows through Keystone transparently, like TCP/IP.

The pipeline is now:
User ↔ Odysseus ↔ ProjectNestor ↔ ProjectAgamemnon ↔ agentic pipeline loop →
completion.

Continuing to depend on ai-maestro alongside these native components creates
split-brain risks:
- Two competing sources of truth for task state (ai-maestro + GitHub Issues).
- Two agent registries (ai-maestro + native component metadata).
- Coupling to an external upstream that we no longer need and cannot fully
  control.

## Decision

Replace ai-maestro with HomericIntelligence native components:

1. **ProjectAgamemnon** becomes the coordinator: plans work, orchestrates state
   machines, dispatches to myrmidons. GitHub Issues are the authoritative
   task/planning store.
2. **ProjectNestor** handles research, ideation, and brief preparation before
   handing to Agamemnon.
3. **ProjectCharybdis** provides chaos testing capabilities via Agamemnon's
   chaos endpoints.
4. **ProjectKeystone** is the universal transport layer:
   - All inter-component communication flows through NATS streams.
   - Named NATS streams: `hi.research.>`, `hi.myrmidon.{type}.>`,
     `hi.pipeline.>`, `hi.agents.>`, `hi.tasks.>`, `hi.logs.>`.
   - BlazingMQ for low-latency financial-grade messaging where needed.
   - Pull-based architecture: myrmidons pull work when ready
     (MaxAckPending=1 rate limit).
   - Tailscale WireGuard mesh VPN across all nodes.

5. Remove the `infrastructure/ai-maestro` submodule from Odysseus after
   migration is complete.

## Consequences

**Positive:**
- Full control: No external dependency on ai-maestro. All behavior is defined
  and owned by HomericIntelligence.
- Single source of truth: GitHub Issues + Agamemnon state machines replace
  ai-maestro's distributed task model.
- Pull-based architecture: Myrmidons pull work at their own pace
  (rate-limited). No queue overflow or push-based backpressure issues.
- Native mesh architecture: Keystone's NATS streams and Tailscale provide
  transparent routing without a separate coordination layer.
- Loose coupling: Components communicate via well-defined streams, not tight
  REST API contracts.

**Negative:**
- Migration effort: Existing ai-maestro integrations in legacy repos must be
  rewritten to use Agamemnon + Keystone.
- Operational complexity: Operating our own coordinator (Agamemnon) and
  transport layer (Keystone) requires expertise in C++20, NATS, and BlazingMQ.

**Neutral:**
- The `infrastructure/ai-maestro` submodule will be removed from Odysseus after
  all repos have migrated. Legacy integration code remains in version control
  for historical reference.
- ai-maestro itself remains available for external use, but is no longer a
  HomericIntelligence dependency.
