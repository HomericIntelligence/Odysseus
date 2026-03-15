# ADR 004: Extend ai-maestro via APIs Rather Than Replacing Its Capabilities

**Status:** Accepted

---

## Context

ai-maestro is the core platform of the HomericIntelligence ecosystem. It provides a well-defined REST API covering:
- Agent lifecycle management (`/agents`)
- Task queuing and dispatch (`/tasks`)
- Agent-to-agent messaging via AMP (`/messages`)
- Persistent memory and knowledge storage (`/memory`)
- Container creation via Docker socket (`/docker/create`)
- Multi-host peer synchronization (`/host-sync`)
- Outbound webhooks on events

As the ecosystem grows, there is a recurring temptation to either (a) modify ai-maestro source code to add new capabilities, or (b) build new services that duplicate ai-maestro capabilities (e.g., a second agent registry, a second task queue).

Both approaches create problems:
- Modifying ai-maestro creates a fork that diverges from upstream and becomes a maintenance burden.
- Duplicating capabilities creates split-brain state: two sources of truth for agent state, competing task queues, conflicting memory stores.

## Decision

All HomericIntelligence repos integrate with ai-maestro **exclusively via its documented REST API and webhook endpoints**. No new repo:
- Modifies ai-maestro source code.
- Maintains its own agent registry separate from ai-maestro.
- Maintains its own task queue separate from ai-maestro.
- Maintains its own memory/knowledge store intended to replace ai-maestro memory.
- Bypasses ai-maestro by speaking directly to its internal data stores.

New capabilities are implemented as separate services that call ai-maestro as their source of truth:
- Myrmidons applies desired state by calling `/agents` and `/tasks` — it does not maintain a separate live state.
- ProjectTelemachy orchestrates workflows by chaining `/tasks` calls — it does not have its own task engine.
- ProjectArgus observes the system by querying ai-maestro endpoints — it does not have its own agent state.

The `infrastructure/ai-maestro` submodule in Odysseus is pinned read-only. No commits to it. No branches from it.

## Consequences

**Positive:**
- ai-maestro remains the single source of truth for agent state, tasks, and messaging. No split-brain scenarios.
- All new repos can be added, removed, or replaced without affecting ai-maestro or each other (loose coupling via REST).
- ai-maestro upstream updates can be pulled in cleanly (update the submodule SHA) without merge conflicts.
- New developers have one authoritative place to look for agent state: ai-maestro's API.

**Negative:**
- Some capabilities that would be simpler to implement inside ai-maestro require an extra network hop via REST. This is an acceptable trade-off for the architectural clarity gained.
- If ai-maestro's API lacks a needed capability, the only options are: (a) work around it with existing endpoints, (b) request the feature upstream, or (c) accept the limitation. We cannot patch it ourselves.

**Neutral:**
- This ADR does not prohibit reading ai-maestro's database for observability purposes (e.g., ProjectArgus scraping a metrics endpoint), as long as the reads are non-destructive and non-authoritative.
- AMP (agent-to-agent messaging) remains the correct channel for agent communication. New repos should not build a parallel messaging system.
