# Architectural Analysis: HomericIntelligence/Odysseus and ai-maestro

**Date:** 2026-03-28
**Repositories:**
- Odysseus: `HomericIntelligence/Odysseus` (`/home/mvillmow/.agent-brain/Odysseus`)
- ai-maestro: `23blocks-OS/ai-maestro` v0.26.5 (`/home/mvillmow/ai-maestro`)

---

## 1. Executive Summary

ai-maestro is far richer than Odysseus's documentation implies. Odysseus treats ai-maestro as a simple REST platform with six endpoints (`/agents`, `/tasks`, `/messages`, `/memory`, `/docker/create`, `/host-sync`). In reality, ai-maestro v0.26.5 exposes **~100 REST API routes**, a **WebSocket layer** (terminal streaming, real-time status, AMP messaging), an **embedded CozoDB database** per agent with vector embeddings and semantic search, a **cerebellum subsystem** (memory consolidation, voice, terminal buffering), a **code graph** engine (ts-morph + Cytoscape.js), a **full web dashboard** (Next.js 14 + xterm.js), and a **plugin/skills system** with a marketplace.

The HomericIntelligence ecosystem is using approximately **10% of ai-maestro's API surface**. This analysis maps the full capability set, identifies the integration gaps, and proposes how the ecosystem can leverage the 90% it currently ignores — particularly ai-maestro's built-in memory, search, teams/tasks, agent identity (AID), and skills systems.

---

## 2. ai-maestro: What It Actually Is

### 2.1 Architecture Overview

ai-maestro is a **web dashboard for orchestrating AI coding agents** running in tmux sessions. It is not a minimal REST API — it is a full application:

```
┌─────────────────────────────────────────────────────────┐
│                    ai-maestro v0.26.5                    │
├─────────────────────────────────────────────────────────┤
│  Frontend: Next.js 14 + React 18 + xterm.js + Tailwind │
│  ├── Agent dashboard (virtual tabs, instant switching)  │
│  ├── Terminal streaming (WebGL renderer, Unicode 11)    │
│  ├── Kanban board (5-column, drag-and-drop)             │
│  ├── Team meetings (split-pane war rooms)               │
│  ├── Code graph (Cytoscape.js + dagre layout)           │
│  └── Agent playback (time-travel through sessions)      │
├─────────────────────────────────────────────────────────┤
│  Backend: Custom server.mjs (Node.js HTTP + WebSocket)  │
│  ├── ~100 REST API routes (Next.js App Router)          │
│  ├── Headless mode (regex router, no Next.js)           │
│  ├── 4 WebSocket endpoints (/term, /status, /v1/ws,    │
│  │   /companion-ws)                                     │
│  ├── 24 service files (business logic layer)            │
│  └── PM2 process management                             │
├─────────────────────────────────────────────────────────┤
│  Data: CozoDB (embedded Datalog + SQLite)               │
│  ├── Per-agent database (~/.aimaestro/agents/{id}/)     │
│  ├── Vector embeddings (HuggingFace Transformers+ONNX)  │
│  ├── Hybrid search (semantic + BM25 + fusion)           │
│  ├── Long-term memory (facts, patterns, decisions...)   │
│  └── Code graph storage                                 │
├─────────────────────────────────────────────────────────┤
│  Protocols                                              │
│  ├── AMP v0.1.3 (Agent Messaging Protocol)              │
│  │   ├── Ed25519 cryptographic signatures               │
│  │   ├── API key auth (SHA-256 hashed, rate-limited)    │
│  │   ├── Federation (cross-host delivery)               │
│  │   └── Real-time WebSocket + tmux push notifications  │
│  ├── AID v0.2.0 (Agent Identity) — independent of AMP  │
│  └── Host mesh sync (gossip protocol, peer exchange)    │
├─────────────────────────────────────────────────────────┤
│  Storage: File-based JSON registries                    │
│  ├── ~/.aimaestro/agents/registry.json                  │
│  ├── ~/.aimaestro/webhooks.json                         │
│  ├── ~/.aimaestro/hosts.json                            │
│  ├── ~/.aimaestro/amp-api-keys.json                     │
│  └── ~/.aimaestro/teams/tasks-{teamId}.json             │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Tech Stack

| Component | Technology |
|-----------|-----------|
| Runtime | Node.js (custom server.mjs wrapping Next.js 14) |
| Frontend | React 18, xterm.js 6.0, Tailwind CSS, Cytoscape.js |
| Database | CozoDB 0.7.6 (Datalog + SQLite) — one DB per agent |
| Embeddings | HuggingFace Transformers 3.8.1 + ONNX Runtime |
| Process management | PM2, tmux |
| Container runtime | Docker/Podman socket |
| Crypto | Ed25519 keypairs (node:crypto) |
| Dual mode | `MAESTRO_MODE=full` (Next.js) or `headless` (regex router) |

### 2.3 Version and Activity

- **Current version:** 0.26.5 (released 2026-03-26)
- **Stars:** 566 | **Forks:** 78
- **License:** MIT
- **Recent velocity:** 18 releases in 7 weeks (v0.21.24 → v0.26.5)
- **Active development:** AMP protocol fixes, Agent Identity (AID) integration, plugin system
- **Open issues:** 9 | **Recently closed:** 30+ in March 2026 alone

---

## 3. The Integration Gap: What Odysseus Uses vs. What Exists

### 3.1 Odysseus's View of ai-maestro (from architecture.md and ADRs)

Odysseus documents ai-maestro as providing six capabilities:

```
1. /agents        — Agent registry and lifecycle
2. /tasks         — Task queue and dispatch
3. /messages      — Agent-to-agent messaging (AMP)
4. /memory        — Persistent memory/knowledge store
5. /docker/create — Container creation via Docker socket
6. /host-sync     — Multi-host peer sync
```

### 3.2 What Actually Exists (~100 Routes)

| Route Group | Odysseus Uses | ai-maestro Provides | Gap |
|-------------|---------------|---------------------|-----|
| **Agents CRUD** | GET/POST/DELETE `/api/agents` | 30+ agent routes (session, hibernate, wake, transfer, import/export, skills, metadata, brain-inbox, playback, subconscious, tracking, metrics, docs, graph, repos) | **~85% unused** |
| **Tasks** | GET/PUT `/api/teams/{id}/tasks` | Full team-scoped task CRUD with 5-status kanban, dependencies, drag-and-drop UI | Used correctly, but Odysseus docs say `/tasks` (no team scope) |
| **Messages** | Not directly used by satellites | Full AMP v0.1.3 with Ed25519 signatures, federation, WebSocket real-time, read receipts, forwarding, batch ack | **Entirely unused by ecosystem** |
| **Memory** | Not used by any satellite | Per-agent CozoDB with vector embeddings, hybrid search (semantic + BM25), long-term memory consolidation (facts, patterns, decisions, insights), delta indexing | **Entirely unused by ecosystem** |
| **Docker** | Referenced in runbook only | Full container lifecycle: create, health, port allocation (23001-23100), resource limits, remote host forwarding | Minimally used |
| **Host sync** | Referenced in add-host runbook | Gossip-based mesh sync, peer exchange, identity, health checks, circular propagation prevention | Used for onboarding only |
| **Webhooks** | ProjectHermes receives 3 event types | 4 webhook event types: `agent.created`, `agent.updated`, `agent.deleted`, `agent.email.changed` | `agent.email.changed` may not be mapped to NATS |
| **Teams** | ProjectKeystone reads teams | Full team CRUD, documents, notifications | Teams used for task scoping only |
| **Sessions** | Not used | tmux session CRUD, command execution, activity monitoring, restore, rename | **Entirely unused** |
| **Agent chat** | Not used | Conversation history per agent | Unused |
| **Agent search** | Not used | Hybrid/semantic/BM25 search over conversations | **Major capability gap** |
| **Agent skills** | Not used | Skills CRUD, settings, marketplace | Unused |
| **Agent graph** | Not used | Code graph (ts-morph), DB schema graph, Cytoscape visualization | Unused |
| **Meetings** | Not used | Team meetings CRUD, split-pane war rooms | Unused |
| **Domains** | Not used | Domain management | Unused |
| **Marketplace** | Not used | Skills marketplace browser | Unused |
| **Plugin builder** | Not used | Scan repo, build plugin, push to GitHub | Unused |
| **AID** | Not used | Agent Identity protocol v0.2.0 (independent of AMP) | Unused |
| **WebSocket** | Not used | Terminal streaming, real-time status, AMP live, companion | Unused |
| **Diagnostics** | Not used | System diagnostics endpoint | Unused |

### 3.3 Integration Surface Currently Used (by ProjectKeystone)

From `/home/mvillmow/ProjectKeystone/src/keystone/maestro_client.py`:

```python
# The entire ai-maestro integration in the HomericIntelligence ecosystem:
GET  /api/teams/{team_id}/tasks    # Fetch tasks for DAG advancement
GET  /api/agents/unified           # Fetch all agents for assignment
GET  /api/teams                    # Fetch all teams for scanning
PUT  /api/teams/{team_id}/tasks/{task_id}  # Update task (assign + status change)
```

That's **4 endpoints** out of ~100.

---

## 4. ai-maestro's Agent Model (What Odysseus Doesn't Know)

### 4.1 Agent Entity (Full Shape)

From `types/agent.ts` — ai-maestro agents are far richer than Odysseus assumes:

```typescript
interface Agent {
  id: string                        // UUID
  name: string                      // Identity name
  label?: string                    // Auto-generated persona name (from hash)
  avatar?: string                   // Auto-assigned avatar URL
  ampIdentity?: AMPAgentIdentity    // Ed25519 cryptographic identity

  // Execution context
  workingDirectory?: string
  sessions: AgentSession[]          // 0+ tmux sessions
  hostId: string
  program: string                   // "Claude Code" | "Aider" | "Cursor" | ...
  model?: string                    // "Opus 4.1" | "GPT-4" | ...
  runtime?: 'tmux' | 'docker' | 'api' | 'direct'

  // Organization
  taskDescription: string
  tags?: string[]
  capabilities?: string[]
  owner?: string
  role?: 'manager' | 'chief-of-staff' | 'member'
  team?: string

  // State
  status: AgentStatus               // active, hibernated, deleted...
  metrics?: AgentMetrics
  metadata?: Record<string, any>
  deployment: AgentDeployment        // local or cloud
  tools: AgentTools                  // session, email, AMP tools
  skills?: AgentSkillsConfig
  deletedAt?: string                 // Soft-delete support
}
```

**Key insight:** Odysseus's ADR-001 models agents as containers (Dockerfiles with `LABEL ai.maestro.agent-type`). But ai-maestro models agents as **tmux sessions running AI coding tools** — Claude Code, Aider, Cursor, etc. The container model is secondary (`runtime: 'docker'` is one of four runtime options).

### 4.2 Agent Capabilities Odysseus Ignores

| Capability | ai-maestro Feature | Odysseus Status |
|------------|-------------------|-----------------|
| **Hibernation** | `POST /api/agents/{id}/hibernate` — detach session, preserve state | Not used |
| **Wake** | `POST /api/agents/{id}/wake` — reattach session | Not used |
| **Transfer** | `POST /api/agents/{id}/transfer` — move to another host | Not used — Odysseus uses Nomad instead |
| **Import/Export** | `POST /api/agents/{id}/import` (ZIP), `GET /api/agents/{id}/export` | Not used |
| **Playback** | `GET /api/agents/{id}/playback` — time-travel through sessions | Not used |
| **Subconscious** | `POST /api/agents/{id}/subconscious` — background processing | Not used |
| **Brain inbox** | `GET /api/agents/{id}/brain-inbox` — cerebellum signals | Not used |
| **Skills** | `GET/PATCH /api/agents/{id}/skills` — configurable skills per agent | Not used |
| **Metrics** | `GET /api/agents/{id}/metrics` — performance tracking | Not used |
| **Docs** | `GET/POST /api/agents/{id}/docs` — documentation indexing | Not used |
| **Code graph** | `GET/POST /api/agents/{id}/graph/code` — codebase visualization | Not used |
| **Repos** | `GET/POST /api/agents/{id}/repos` — git repo management | Not used |
| **Tracking** | `GET/POST /api/agents/{id}/tracking` — progress tracking | Not used |
| **Metadata** | `GET/PATCH /api/agents/{id}/metadata` — flexible KV store | Not used |

### 4.3 Task System: What Odysseus Gets Wrong

**Odysseus docs say:** `/tasks` — a standalone task endpoint.
**Reality:** Tasks are **team-scoped** at `/api/teams/{id}/tasks`. There is no top-level `/tasks` endpoint.

**Implications:**
- Myrmidons would need team IDs to manage tasks (the docs don't mention this)
- ProjectTelemachy would need team context for workflow chaining
- The architecture doc's simplified notation (`/tasks`) hides a meaningful constraint

**Task status lifecycle in ai-maestro:**
```
backlog → pending → in_progress → review → completed
                                         → failed
                                         → error
                                         → cancelled
```

ProjectKeystone correctly models this with `TaskStatus` enum including `BACKLOG`, `PENDING`, `IN_PROGRESS`, `REVIEW`, `COMPLETED`, `FAILED`, `ERROR`, `CANCELLED`.

---

## 5. ai-maestro's Memory System (Odysseus's Biggest Missed Opportunity)

### 5.1 What Exists

ai-maestro has a **three-layer memory architecture** that the HomericIntelligence ecosystem completely ignores:

**Layer 1 — Conversation Memory (CozoDB + Vector Embeddings)**
```
Per-agent CozoDB at ~/.aimaestro/agents/{id}/agent.db
  ├── sessions table      — conversation session metadata
  ├── conversations table — conversation entries
  ├── messages table      — individual messages with embeddings
  └── msg_vec table       — vector index for semantic search
```

Conversations are ingested from `~/.claude/projects/` JSONL files via delta indexing. Each message gets a HuggingFace embedding (ONNX Runtime, local inference).

**Layer 2 — Long-Term Memory (Consolidated)**
```
Memory categories:
  facts       — objective information discovered
  preferences — user/agent preferences
  patterns    — recurring patterns observed
  decisions   — decisions made and rationale
  insights    — synthesized observations

Memory metadata:
  confidence  — 0.0-1.0 confidence score
  tier        — core | standard | peripheral
  reinforced  — count of reinforcements
```

Memory consolidation runs as a background process, extracting structured knowledge from raw conversations and storing it in categorized, searchable form.

**Layer 3 — Code Graph (ts-morph)**
```
Code analysis via ts-morph:
  ├── Function/class/variable extraction
  ├── Import/export dependency mapping
  ├── Call graph construction
  └── Cytoscape.js interactive visualization
```

### 5.2 Search Capabilities

ai-maestro supports **three search modes** (per agent):

| Mode | Method | Use Case |
|------|--------|----------|
| Semantic | HuggingFace embeddings + vector cosine similarity | "Find conversations about authentication" |
| BM25 | Term frequency / inverse document frequency | "Find exact mentions of `webhook_secret`" |
| Hybrid | Reciprocal Rank Fusion (RRF) of semantic + BM25 | Best of both — default mode |

**API:**
```
GET /api/agents/{id}/search?q=...&mode=hybrid
POST /api/agents/{id}/search           # Ingest conversations
POST /api/agents/{id}/index-delta      # Delta indexing (new conversations only)
```

### 5.3 Why This Matters for HomericIntelligence

**Current state:** The ecosystem has zero memory utilization. ADR-004 says "no new repo maintains its own memory/knowledge store." But it also doesn't _use_ ai-maestro's memory store. Agents in the ecosystem have no long-term memory, no semantic search, and no pattern recognition.

**What could change:**
1. ProjectKeystone could query agent memory before DAG advancement — "has this agent successfully handled similar tasks before?"
2. ProjectTelemachy could store workflow execution history in agent memory — searchable by future workflow runs
3. ProjectArgus could consolidate metrics into long-term memory patterns — "which agent types fail most often on which task types?"

---

## 6. AMP Protocol: Deeper Than Documented

### 6.1 Current AMP Architecture (v0.1.3)

```
Agent A                    ai-maestro                    Agent B
  │                            │                            │
  ├─ POST /v1/register ───────►│ (generates API key)        │
  │  ◄── amp_live_sk_... ──────┤                            │
  │                            │                            │
  ├─ POST /v1/route ──────────►│ (verify Ed25519 sig)       │
  │  {to: "B", content: ...}   │                            │
  │                            ├── Write to B's amp-inbox/ ─►│
  │                            ├── WebSocket push (/v1/ws) ─►│
  │                            ├── tmux notification ───────►│
  │                            │                            │
  │                            │◄── GET /v1/messages ────────┤
  │                            │    (poll pending)           │
  │                            │◄── DELETE /v1/messages/     │
  │                            │    pending/{id} (ack)       │
```

**Security features:**
- Ed25519 keypairs per agent (stored at `~/.aimaestro/agents/{id}/keys/`)
- API keys: SHA-256 hashed storage, 24-hour grace period on rotation
- Rate limiting: 60 requests/agent/60 seconds on `/v1/route`
- Content security: 34 prompt injection patterns scanned, external content wrapped in `<external-content>` tags
- Proof-of-possession for key rotation (v0.25.15)

**Federation:** Messages to agents on other hosts route via `POST /v1/federation/deliver` to remote ai-maestro instances. The host mesh (`/api/hosts/`) provides peer discovery.

### 6.2 Agent Identity (AID) v0.2.0

As of v0.26.0, ai-maestro includes AID — an identity protocol **independent of AMP**:
- Ed25519 identity documents
- Proof of possession
- OAuth 2.0 token exchange
- Scoped JWT tokens

This was not documented in any Odysseus ADR or architecture doc.

### 6.3 What Odysseus Misses

The HomericIntelligence ecosystem routes all inter-agent communication through NATS JetStream (ADR-002). But ai-maestro's AMP protocol provides:

| AMP Feature | NATS Equivalent | Gap |
|-------------|-----------------|-----|
| Cryptographic signatures | None | NATS messages are unsigned |
| Per-agent identity (Ed25519) | None | NATS has no agent identity |
| Read receipts | None | NATS has at-least-once, no read confirmation |
| Message forwarding | None | No built-in forward |
| Content security scanning | None | No prompt injection detection |
| Agent card / directory | None | No agent discovery protocol |
| Real-time WebSocket | None (NATS is server-side) | No browser push |

**Architectural tension:** ADR-002 states "AMP stays as the point-to-point channel for agent-to-agent communication... NATS is for infrastructure events only." But in practice, the ecosystem doesn't use AMP at all — it routes everything through NATS. AMP's richer security model is being bypassed.

---

## 7. Webhook System: Mismatches and Gaps

### 7.1 Webhook Events

ai-maestro fires four webhook event types:

| Event | Description | Mapped to NATS? |
|-------|-------------|------------------|
| `agent.created` | Agent registered | Yes → `hi.agents.{host}.{name}.created` |
| `agent.updated` | Agent state changed | Yes → `hi.agents.{host}.{name}.updated` |
| `agent.deleted` | Agent removed | Yes → `hi.agents.{host}.{name}.deleted` |
| `agent.email.changed` | Agent email addresses changed | **Unknown — likely dropped** |

### 7.2 Missing Task Webhooks

**Critical finding:** ai-maestro's webhook system only fires on **agent events**. There are **no webhook events for task status changes**.

ProjectKeystone's NATS listener subscribes to `hi.tasks.>`, expecting task events. But if ai-maestro doesn't fire task webhooks, how does ProjectHermes publish task events to NATS?

**Possible explanations:**
1. ProjectHermes polls ai-maestro's task endpoints and generates synthetic NATS events
2. ai-maestro has undocumented task webhook support not visible in the webhook service code
3. The task NATS pipeline is not yet operational

This is a **critical architectural question** that could not be resolved without inspecting ProjectHermes's source (submodule not checked out).

### 7.3 Webhook Delivery Model

```
Delivery: Fire-and-forget via Promise.allSettled()
Timeout:  10 seconds per delivery
Retry:    None — failure count tracked but no retry queue
Security: HMAC-SHA256 signature in X-Webhook-Signature header
          (secret generated as whsec_{64 hex chars} on webhook creation)
```

**Gap:** No retry queue. If ProjectHermes is down when an event fires, the event is lost. NATS JetStream's durable consumers handle replay on the NATS side, but the webhook-to-Hermes link is fragile. This was identified in ai-maestro's BACKLOG.md as "Host Sync Phase 3 (retry queue for offline hosts with exponential backoff) not implemented."

---

## 8. Host Mesh: What Odysseus Duplicates

### 8.1 ai-maestro's Built-in Mesh

ai-maestro has a **gossip-based mesh networking** system built in:

```
POST /api/hosts/register-peer     — Register as peer
POST /api/hosts/exchange-peers    — Exchange known peer lists
POST /api/hosts/sync              — Full mesh sync trigger
GET  /api/hosts/identity          — This host's identity
GET  /api/hosts/health            — Remote host health
```

Features:
- Auto-detect public URL (Tailscale IP preferred, then LAN, then hostname)
- Circular propagation prevention via `propagationId` (60s TTL, max 3 hops)
- Organization adoption from peer hosts
- Health checks (5s timeout), registration (10s), exchange (15s)

### 8.2 Overlap with Odysseus Infrastructure

Odysseus adds **three additional networking layers** on top of ai-maestro's built-in mesh:

| Layer | System | Purpose | Overlap with ai-maestro? |
|-------|--------|---------|--------------------------|
| Network mesh | Tailscale | WSL2 host-to-host connectivity | ai-maestro auto-detects Tailscale IPs |
| Container scheduling | Nomad | Schedule containers across hosts | ai-maestro has `/docker/create` + remote forwarding |
| Event distribution | NATS leaf nodes | Multi-host event mesh | ai-maestro has `/host-sync` + federation |

**Key question:** Is this layering necessary, or is it duplicating what ai-maestro already provides?

**Analysis:**
- **Tailscale:** Necessary — ai-maestro needs network connectivity but doesn't provide it
- **Nomad:** Partially redundant — ai-maestro's `/docker/create` supports remote host forwarding (`hostId` parameter routes to remote host's API), but Nomad provides richer scheduling (constraints, resource allocation, job specs). **Nomad adds genuine value beyond ai-maestro's capabilities.**
- **NATS:** Necessary for fan-out — ai-maestro's webhooks are single-target, fire-and-forget. NATS JetStream adds durable pub/sub fan-out that ai-maestro does not provide. However, ai-maestro's AMP federation could partially replace NATS for agent-to-agent messaging.

---

## 9. Known Issues and Roadmap (from GitHub)

### 9.1 Open Issues (9)

| # | Title | Relevance to Odysseus |
|---|-------|-----------------------|
| **291** | Agent-program normalization and terminal-default patch | Medium — affects how agents report their program type |
| **285** | DRY: Shared API validation middleware for 106 routes | Low — internal code quality |
| **270** | Paste screenshots / upload files to agents | Low — UI feature |
| **248** | Robotic avatars fixed | Low — cosmetic |
| **241** | Team-based communication isolation | **HIGH** — proposes MANAGER/CHIEF-OF-STAFF roles, open/closed teams, messaging restrictions. Would significantly change how the ecosystem models agent organization |
| **237** | Decouple voice subsystem from Claude Code files | Low — voice feature |
| **236** | Decouple conversation indexing from Claude Code format | **HIGH** — currently hardcoded to `~/.claude/projects/` JSONL. Decoupling would allow indexing from any agent type |
| **197** | Personal Assistant agents (Discord, WhatsApp, Telegram) | Medium — new agent runtime types |

### 9.2 Recently Closed Issues (Notable)

| # | Title | Lesson for Odysseus |
|---|-------|-----------------------|
| **295** | AMP data not cleaned up on soft-delete | Agent deletion has hidden state — Odysseus needs to handle this |
| **292** | Soft-deleted agents reappear in UI as hibernating | Soft-delete semantics are subtle — `GET /api/agents` may return deleted agents |
| **286** | CozoDB query injection via unescaped template literals | **Security** — ai-maestro had a query injection vulnerability; fixed in March 2026 |
| **279** | `/plan` mode rendering in xterm.js | Terminal rendering bugs affect Claude Code specifically |
| **276** | `agent.hostUrl` used directly breaks on WSL2/NAT | Cross-host URLs unreliable — Odysseus should use Tailscale IPs, not hostUrl |
| **273** | Dashboard shows no agents on WSL2: unreachable internal IP | WSL2 networking issues — directly affects HomericIntelligence's target platform |
| **252** | `useTasks` crashes on unknown task status | Task status values must be validated — relates to ecosystem-audit-remediation finding |
| **251** | Task update (PUT) overwrites existing fields with undefined | **Critical for ProjectKeystone** — PUT semantics require sending ALL fields, not just changed ones. Partial updates silently null out omitted fields. |

### 9.3 Development Trajectory

ai-maestro is moving fast (18 releases in 7 weeks). Key directions:
- **AMP protocol hardening** — v0.1.3 with key rotation, proof-of-possession, mesh routing fixes
- **Agent Identity (AID)** — v0.2.0, now independent from AMP
- **Plugin/skills system** — dynamic discovery, auto-install, marketplace
- **OpenClaw compatibility** — decoupling from Claude Code-specific file formats

---

## 10. Documented Integration Mismatches

### 10.1 Confirmed Mismatches

| Issue | Odysseus Says | ai-maestro Actually Does | Impact |
|-------|---------------|--------------------------|--------|
| **Task endpoint** | `/tasks` (standalone) | `/api/teams/{id}/tasks` (team-scoped) | Myrmidons and Telemachy need team IDs |
| **NATS prefix** | ADR-002 examples use `maestro.*` | Implemented as `hi.*` (ADR-005 corrects this) | Fixed in ADR-005, but disaster-recovery runbook still has stale `maestro.>` reference |
| **Durable consumer** | ADR-005 says `keystone-dag` | ProjectKeystone code uses `keystone-daemon` | Documentation/code mismatch — two different consumer names |
| **API prefix** | Architecture docs use `/agents`, `/tasks` | Actual routes are `/api/agents`, `/api/teams/{id}/tasks` | Shorthand in docs hides real path structure |
| **Webhook events** | Implies events for all entity types | Only `agent.*` events — no `task.*` webhook events | Task NATS pipeline may not be functional via webhooks |
| **PUT semantics** | Not documented | PUT overwrites all fields — omitted fields become undefined (issue #251) | ProjectKeystone MUST send complete task objects, not partial updates |
| **Soft-delete** | Not documented | `DELETE /api/agents/{id}` is soft-delete by default; `?hard=true` for permanent | Deleted agents may still appear in `GET /api/agents` responses |
| **Agent email changed** | Not mapped in ADR-005 | `agent.email.changed` webhook event type exists | No NATS subject for email change events |

### 10.2 Potential Silent Failures

1. **Task PUT partial update bug (issue #251):** If ProjectKeystone calls `PUT /api/teams/{id}/tasks/{taskId}` with only `{"assigneeAgentId": "...", "status": "in_progress"}`, all other task fields (title, dependencies, etc.) will be overwritten with `undefined`. This was fixed in ai-maestro but the fix may require sending the complete task object.

2. **Soft-deleted agents in unified list:** `GET /api/agents/unified` may include soft-deleted agents. ProjectKeystone's DAG walker should filter by `deletedAt` being null/undefined.

3. **hostUrl reliability (issue #276):** `agent.hostUrl` can contain unreachable internal IPs on WSL2. The ecosystem should use Tailscale IPs from host-sync, not hostUrl from agent records.

---

## 11. Untapped Capabilities: What the Ecosystem Should Use

### 11.1 Immediate Value (No Architecture Changes)

**1. Agent Memory and Search**

ProjectKeystone could use ai-maestro's memory system for intelligent task assignment:

```bash
# Before assigning task to agent, check if agent has relevant experience
GET /api/agents/{id}/search?q=<task_description>&mode=hybrid

# Store task completion context for future reference
POST /api/agents/{id}/memory/long-term
{
  "category": "patterns",
  "content": "Successfully completed DAG task: <description>",
  "confidence": 0.9,
  "tier": "standard"
}
```

**2. Agent Metrics**

ProjectArgus could read agent metrics directly instead of inferring from NATS events:

```bash
GET /api/agents/{id}/metrics
# Returns: tasks completed, success rate, average execution time
```

**3. Agent Skills**

AchaeanFleet vessel definitions could include skills configuration:

```bash
PATCH /api/agents/{id}/skills
{
  "enabled": ["code-review", "test-generation", "security-audit"],
  "settings": { "preferredLanguage": "python" }
}
```

**4. Agent Hibernation/Wake**

Instead of stopping and recreating agents, use ai-maestro's built-in lifecycle:

```bash
POST /api/agents/{id}/hibernate   # Detach session, preserve state
POST /api/agents/{id}/wake        # Reattach session
```

### 11.2 Medium-Term Value (Minor Architecture Changes)

**5. AMP for Agent-to-Agent Communication**

ADR-002 already states AMP should be used for agent messaging. The ecosystem could actually implement this:

```bash
# Register agent with AMP
POST /api/v1/register
{
  "agentId": "keystone-daemon",
  "capabilities": ["dag-advancement", "task-routing"]
}

# Send signed message
POST /api/v1/route
{
  "to": "target-agent-id",
  "content": { "type": "request", "message": "Please review PR #42" },
  "signature": "<ed25519_signature>"
}
```

Benefits over NATS for agent messaging: cryptographic verification, read receipts, content security scanning, real-time WebSocket delivery.

**6. Team-Scoped Organization**

Use ai-maestro's teams system to organize the ecosystem's agents:

```bash
POST /api/teams
{ "name": "infrastructure", "agents": ["hermes", "argus", "keystone"] }

POST /api/teams
{ "name": "provisioning", "agents": ["myrmidons", "telemachy"] }
```

**7. Agent Transfer Instead of Nomad Reschedule**

For simple agent migration between hosts:

```bash
POST /api/agents/{id}/transfer
{ "targetHostId": "hermes-host" }
```

This leverages ai-maestro's built-in host mesh instead of Nomad rescheduling.

### 11.3 Long-Term Value (Architectural Leverage)

**8. CozoDB as Ecosystem Knowledge Base**

Each agent's CozoDB could store ecosystem-level knowledge:

```
Agent "keystone-daemon":
  memory: DAG patterns, task dependencies, failure modes
  code_graph: ecosystem service dependencies

Agent "hermes-bridge":
  memory: webhook reliability patterns, NATS subject evolution
  long_term: consolidation of event flow anomalies
```

**9. Plugin System Integration**

ai-maestro's plugin builder could create HomericIntelligence-specific plugins:

```bash
POST /api/plugin-builder/scan
{ "repoPath": "/home/mvillmow/ProjectKeystone" }

POST /api/plugin-builder/build
# Generates a Claude Code plugin from ProjectKeystone
```

---

## 12. Authentication: The Elephant in the Room

### 12.1 Current State

ai-maestro has **no authentication on its HTTP API** (Phase 1 design choice from `.env.example`):

> "Phase 1 - Local-only, auto-discovery, no authentication."

AMP has authentication (API keys + Ed25519), but the REST API is wide open.

### 12.2 Implications for Odysseus

- Any host on the Tailscale mesh can call any ai-maestro endpoint without credentials
- `MAESTRO_API_KEY` exists in ProjectKeystone's config but defaults to empty string
- No RBAC, no scoped tokens, no rate limiting on REST API (only on AMP `/v1/route`)
- This is acceptable for a local development tool but **problematic for a production agent mesh**

### 12.3 Future Path

AID v0.2.0 (introduced in v0.26.0) provides the foundation for REST API authentication:
- Ed25519 identity documents
- OAuth 2.0 token exchange
- Scoped JWT tokens

The ecosystem should plan for ai-maestro eventually requiring authentication on REST endpoints. ProjectKeystone's `MAESTRO_API_KEY` config is forward-looking.

---

## 13. Recommendations

### 13.1 Documentation Fixes (Immediate)

1. **Fix architecture.md** endpoint references: `/tasks` → `/api/teams/{id}/tasks`, `/agents` → `/api/agents`, etc.
2. **Fix disaster-recovery runbook** NATS reference: `maestro.>` → `hi.>`
3. **Reconcile durable consumer name**: ADR-005 says `keystone-dag`, code says `keystone-daemon`
4. **Document soft-delete semantics**: `DELETE /api/agents/{id}` is soft-delete by default
5. **Document PUT full-replace semantics**: task updates must send complete objects
6. **Add ADR for ai-maestro memory**: Document decision to use or not use ai-maestro's memory system
7. **Document `agent.email.changed` webhook gap**: Either map to NATS or explicitly exclude

### 13.2 Integration Improvements (Short-Term)

1. **Use agent memory for intelligent assignment**: Query `/api/agents/{id}/search` before task assignment in ProjectKeystone
2. **Use agent metrics in ProjectArgus**: Read `/api/agents/{id}/metrics` instead of inferring from events
3. **Use hibernation instead of stop/start**: `POST /api/agents/{id}/hibernate|wake`
4. **Filter soft-deleted agents**: Add `deletedAt` check in ProjectKeystone's DAG walker
5. **Send complete objects on PUT**: Ensure ProjectKeystone doesn't trigger issue #251

### 13.3 Architectural Decisions Needed (Medium-Term)

1. **AMP vs NATS for agent messaging**: ADR-002 says to use AMP for agent-to-agent, but the ecosystem uses NATS for everything. Decide and document.
2. **ai-maestro memory vs external memory**: Should the ecosystem use ai-maestro's CozoDB + vector search, or build a separate memory layer (as the Ruflo analysis suggested)?
3. **Task webhook gap**: Investigate whether ProjectHermes generates task NATS events from polling or if ai-maestro actually fires task webhooks not visible in the webhook service code.
4. **Authentication timeline**: When will ai-maestro REST API require auth? Plan for `MAESTRO_API_KEY` to become mandatory.
5. **Nomad vs ai-maestro transfer**: For simple agent migration, `POST /api/agents/{id}/transfer` may be simpler than Nomad rescheduling. Define when each is appropriate.

### 13.4 What NOT To Do

- **Do not build a separate memory system** before evaluating ai-maestro's CozoDB + vector search. It already has hybrid search, long-term memory consolidation, and per-agent isolation.
- **Do not duplicate agent identity** — AID v0.2.0 exists in ai-maestro. The ecosystem should adopt it, not create a parallel identity system.
- **Do not bypass webhook+NATS for task events** by polling ai-maestro directly from every consumer. If the webhook→NATS pipeline has gaps, fix the pipeline.

---

## Appendix A: Complete ai-maestro API Route Map

### Agent Routes (~40 endpoints)
```
GET    /api/agents
POST   /api/agents
GET    /api/agents/{id}
PATCH  /api/agents/{id}
DELETE /api/agents/{id}
POST   /api/agents/register
GET    /api/agents/by-name/{name}
GET    /api/agents/unified
GET    /api/agents/directory
GET    /api/agents/directory/lookup/{name}
POST   /api/agents/directory/sync
GET/POST /api/agents/normalize-hosts
GET/POST /api/agents/startup
POST   /api/agents/health
POST   /api/agents/docker/create
POST   /api/agents/import
GET    /api/agents/{id}/session
POST   /api/agents/{id}/session
PATCH  /api/agents/{id}/session
DELETE /api/agents/{id}/session
POST   /api/agents/{id}/wake
POST   /api/agents/{id}/hibernate
GET    /api/agents/{id}/chat
POST   /api/agents/{id}/chat
GET    /api/agents/{id}/memory
POST   /api/agents/{id}/memory
GET/POST/PATCH /api/agents/{id}/memory/consolidate
GET/PATCH/DELETE /api/agents/{id}/memory/long-term
GET    /api/agents/{id}/search
POST   /api/agents/{id}/search
POST   /api/agents/{id}/index-delta
GET/POST /api/agents/{id}/tracking
GET/PATCH /api/agents/{id}/metrics
GET/POST/DELETE /api/agents/{id}/graph/code
GET/POST/DELETE /api/agents/{id}/graph/db
GET    /api/agents/{id}/graph/query
GET/POST /api/agents/{id}/database
GET    /api/agents/{id}/messages
POST   /api/agents/{id}/messages
GET/PATCH/POST/DELETE /api/agents/{id}/messages/{messageId}
GET/POST /api/agents/{id}/amp/addresses
GET/PATCH/DELETE /api/agents/{id}/amp/addresses/{address}
GET/POST /api/agents/{id}/email/addresses
GET/PATCH/DELETE /api/agents/{id}/email/addresses/{address}
GET    /api/agents/email-index
GET/PATCH/POST/DELETE /api/agents/{id}/skills
GET/PUT /api/agents/{id}/skills/settings
GET/POST/DELETE /api/agents/{id}/repos
GET/POST/DELETE /api/agents/{id}/docs
GET/POST /api/agents/{id}/subconscious
GET    /api/agents/{id}/brain-inbox
GET/POST /api/agents/{id}/playback
GET/PATCH/DELETE /api/agents/{id}/metadata
GET/POST /api/agents/{id}/export
POST   /api/agents/{id}/transfer
```

### Team & Task Routes
```
GET/POST /api/teams
GET/PUT/DELETE /api/teams/{id}
GET/POST /api/teams/{id}/tasks
PUT/DELETE /api/teams/{id}/tasks/{taskId}
GET/POST /api/teams/{id}/documents
GET/PUT/DELETE /api/teams/{id}/documents/{docId}
POST /api/teams/notify
```

### Host Routes
```
GET    /api/hosts
POST   /api/hosts
PUT    /api/hosts/{id}
DELETE /api/hosts/{id}
GET    /api/hosts/identity
GET    /api/hosts/health
GET/POST /api/hosts/sync
POST   /api/hosts/register-peer
POST   /api/hosts/exchange-peers
```

### AMP v1 Routes
```
GET    /api/v1/health
GET    /api/v1/info
POST   /api/v1/register
POST   /api/v1/route
GET    /api/v1/messages
GET    /api/v1/messages/pending
DELETE /api/v1/messages/pending
DELETE /api/v1/messages/pending/{id}
POST   /api/v1/messages/pending/ack
POST   /api/v1/messages/{id}/read
GET    /api/v1/agents
GET    /api/v1/agents/me
GET    /api/v1/agents/me/card
PATCH  /api/v1/agents/me
DELETE /api/v1/agents/me
GET    /api/v1/agents/resolve/{address}
DELETE /api/v1/auth/revoke-key
POST   /api/v1/auth/rotate-key
POST   /api/v1/auth/rotate-keys
POST   /api/v1/federation/deliver
```

### Other Routes
```
GET/POST /api/webhooks
GET/DELETE /api/webhooks/{id}
POST /api/webhooks/{id}/test
GET/POST /api/messages
PATCH/DELETE /api/messages
GET /api/messages/meeting
POST /api/messages/forward
GET/POST /api/meetings
GET/PATCH/DELETE /api/meetings/{id}
GET/POST /api/sessions
POST /api/sessions/create
DELETE /api/sessions/{id}
GET/POST /api/sessions/{id}/command
PATCH /api/sessions/{id}/rename
GET/POST/DELETE /api/sessions/restore
GET /api/sessions/activity
POST /api/sessions/activity/update
GET/POST /api/domains
GET/PATCH/DELETE /api/domains/{id}
GET /api/marketplace/skills
GET /api/marketplace/skills/{id}
GET/POST/DELETE /api/help/agent
POST /api/plugin-builder/scan
POST/GET /api/plugin-builder/build
POST /api/plugin-builder/push
GET /api/config
GET /api/organization
POST /api/organization
GET /api/diagnostics
GET /api/docker/info
POST /api/conversations/parse
GET /api/conversations/{file}/messages
GET/DELETE /api/export/jobs/{jobId}
GET /api/subconscious
GET /api/debug/pty
GET /.well-known/agent-messaging.json
```

### WebSocket Endpoints
```
/term?name={sessionName}&host={hostId}   — Terminal streaming
/status                                   — Real-time status updates
/v1/ws                                    — AMP real-time messaging
/companion-ws?agent={agentId}             — Companion app (voice/speech)
```

---

## Appendix B: Ecosystem-to-ai-maestro Integration Map

```
HomericIntelligence Ecosystem
│
├── ProjectKeystone (DAG executor)
│   ├── GET  /api/teams                    ← fetch all teams
│   ├── GET  /api/teams/{id}/tasks         ← fetch tasks per team
│   ├── GET  /api/agents/unified           ← fetch all agents
│   └── PUT  /api/teams/{id}/tasks/{id}    ← assign agent + update status
│
├── ProjectHermes (NATS bridge)
│   └── Receives webhooks: agent.created, agent.updated, agent.deleted
│       └── Publishes to NATS: hi.agents.{host}.{name}.{verb}
│       └── (Task events: mechanism unclear — no task webhooks in ai-maestro)
│
├── Myrmidons (GitOps)
│   ├── POST /api/agents                   ← create agents from YAML
│   ├── DELETE /api/agents/{id}            ← remove agents
│   └── (Tasks: needs /api/teams/{id}/tasks, not /tasks)
│
├── ProjectTelemachy (workflows)
│   └── (Tasks: needs /api/teams/{id}/tasks, not /tasks)
│
├── ProjectArgus (observability)
│   └── (Could use: GET /api/agents/{id}/metrics)
│
├── ProjectScylla (chaos testing)
│   └── (Uses: DELETE/PATCH /api/agents/{id} for failure injection)
│
└── Runbooks
    ├── POST /api/agents/docker/create     ← add-new-agent-type
    ├── POST /api/hosts/sync               ← add-new-host
    ├── GET  /api/agents                   ← disaster-recovery
    └── GET  /health                       ← disaster-recovery

UNUSED by ecosystem (major capabilities):
  ├── Agent memory: /api/agents/{id}/memory, /search, /memory/long-term
  ├── Agent skills: /api/agents/{id}/skills
  ├── Agent metrics: /api/agents/{id}/metrics
  ├── Agent lifecycle: /hibernate, /wake, /transfer, /import, /export
  ├── Agent cerebellum: /subconscious, /brain-inbox
  ├── Agent graph: /graph/code, /graph/db
  ├── AMP messaging: /api/v1/* (entire protocol)
  ├── AID identity: Agent Identity v0.2.0
  ├── Meetings: /api/meetings
  ├── Plugin builder: /api/plugin-builder
  ├── Marketplace: /api/marketplace
  └── WebSocket: /term, /status, /v1/ws, /companion-ws
```

---

## Appendix C: Version History Context

| Version | Date | Significance |
|---------|------|-------------|
| v0.21.24 | 2026-02-08 | AMP Protocol, Mesh Networking, Kanban |
| v0.25.0 | 2026-03-09 | Agent Skills Standard Compliant |
| v0.25.15 | 2026-03-23 | AMP Key Rotation with Proof-of-Possession |
| v0.25.16 | 2026-03-23 | AMP Plugin Sync to v0.1.3 |
| v0.26.0 | 2026-03-24 | Agent Identity (AID) Integration |
| v0.26.1 | 2026-03-24 | Rename installer, auto-discover skills |
| v0.26.2 | 2026-03-24 | Dynamic discovery for all lists |
| v0.26.3 | 2026-03-24 | AID v0.2.0: Independent from AMP |
| v0.26.4 | 2026-03-25 | AMP Mesh Routing Fix |
| v0.26.5 | 2026-03-26 | Auto-install Status Line |
