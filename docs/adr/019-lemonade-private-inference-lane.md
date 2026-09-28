# ADR 019: Lemonade as the Private Inference Lane for the Mesh

**Status:** Proposed

> **Proposal status:** The lane, placement, client wiring, and router policies
> below are desired state. They are not a deployed or binding architecture
> claim; current images, manifests, service configuration, and live readbacks
> remain authoritative.

---

## Context

The HomericIntelligence mesh has **no local inference component** (see the
component inventory in [architecture.md](../architecture.md)):

- **Myrmidons** are Claude Code sessions that call `api.anthropic.com`
  (`ANTHROPIC_API_KEY` / OAuth); every prompt and every dollar leaves the mesh.
- **Nestor, Agamemnon, and Keystone** have no LLM execution path in their
  pinned implementations; the current component inventory in
  [architecture.md](../architecture.md) records their implemented service and
  transport roles. Proposed ADR-013 describes a possible future mesh boundary.
- **Odyssey** is a Mojo *training* framework with no serving path — trained
  checkpoints (AlexNet-CIFAR10, MobileNetV1, LeNet-5) have no deployment
  route into the mesh.

**Lemonade** ([lemonade-server.ai](https://lemonade-server.ai/),
[github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade),
Apache-2.0, community project with AMD optimizations) is an open-source local
AI server exposing **OpenAI-, Anthropic-, and Ollama-compatible REST APIs** on
port `13305` (`/api/v1`). It serves GGUF/ONNX/FLM text models plus TTS, STT,
and image generation via llama.cpp / whisper.cpp / sd-cpp / ONNX Runtime on
CPU, CUDA, ROCm, Metal, and AMD NPU. It ships as a container
(`ghcr.io/lemonade-sdk/lemonade-server`), runs as an unprivileged user, and
supports API-key authentication via `LEMONADE_API_KEY`.

This proposal records measurements reported from a 2026-08-12 epimetheus
spike, in which the container served `Qwen3-0.6B-GGUF` (364.5 MB, Q4_0) on the
4-core i5-6600K CPU backend. The binding evidence-integrity policy is in
[`AGENTS.md`](../../AGENTS.md); Proposed ADR-014 supplies related design
context. The recorded results are:

| Metric | Value |
|---|---|
| Streaming time-to-first-token | ~35 ms (34–37 ms across 5 runs) |
| Round-trip, 64 tokens (non-stream) | ~1.26 s avg (~51 tok/s) |
| Full completion (119 tokens, reasoning + answer) | 2.34 s |
| `GET /live` health | HTTP 200 in 1.3 ms |
| Auth without `LEMONADE_API_KEY` | HTTP 401 (enforced) |
| Cross-host over Tailscale (apollo → epimetheus) | HTTP 200 in 1.6 ms |

The same historical spike report also recorded that rootless Podman 3.4.2 on
epimetheus could not port-publish (`-p` connections reset), so that session
used `--network=host`; it also reported a GTX 1080 that the stock CPU-only
image did not use. No durable run output was retained for those observations,
so activation must re-verify the effective runtime, network, and accelerator
state rather than treating this proposal as operational evidence.

## Decision

**If accepted, Lemonade becomes the mesh's private inference lane — an
optional, additive serving substrate for open-weight models and
OpenAI-compatible client flows.** It does not replace the Anthropic cloud lane
for Claude models (proprietary weights); it replaces the cloud API for
everything that can run on open weights, and it gives Odyssey-trained models a
deployment path.

### 1. Placement

- **Vessel**: a pinned `ghcr.io/lemonade-sdk/lemonade-server` container in
  AchaeanFleet (digest-pinned per repo convention), one instance per fleet
  host that should serve models, running on the `homeric-mesh` Podman network.
- **Networking**: `--network=host` only where an activation-time check proves
  rootless port publishing is broken; otherwise use an explicit loopback or
  operator-approved private-interface port binding. Host networking does not
  imply tailnet-only exposure: activation requires a verified service bind,
  host firewall rule, and local plus remote reachability readback proving that
  no public interface accepts the port.
- **Auth**: `LEMONADE_API_KEY` is mandatory on every instance and its
  server-side enforcement must be proved at activation. The historical spike
  report recorded an HTTP 401 without the key, but no durable receipt is
  retained. Keys are supplied via environment at schedule time, never
  committed.
- **Persistence**: named volumes persist the HuggingFace model cache, llama
  binaries, and recipe config (`lemonade-cache`, `lemonade-llama`,
  `lemonade-recipe`) so models survive container recreation.
- **Backend selection**: CPU backend by default for the initial lane
  (`config.json` in the recipe volume). The historical report says epimetheus
  has a GTX 1080, but the reported stock image did not use it; any GPU path
  requires separate compatibility and runtime proof. When compatible AMD NPU
  (XDNA2) or GPU serving paths are established, ROCm/Vulkan/NPU backends are
  enabled per host, and
  **multi-node VRAM pooling via llama.cpp RPC** (`rpc-server`, port `50053`)
  becomes the mechanism for serving models larger than any single host —
  controller + workers over the tailnet, with the RPC port bound to the
  `tailscale0` zone (firewalld pattern from the fleet runbook).

### 2. Transport and NATS events

Inference is synchronous request/response and rides **OpenAI-compatible REST
(`http://lemonade:13305/api/v1`) over the mesh — never NATS**. NATS carries
only lifecycle and observability signals, extending the ADR-005/013 subject
namespace:

| Subject | Publisher | Consumers | Meaning |
|---|---|---|---|
| `hi.agents.{host}.lemonade.created` | Proposed deployment controller through Hermes | Argus, Telemachy | Instance registered, healthy |
| `hi.agents.{host}.lemonade.updated` | Proposed deployment controller through Hermes | Argus | Model load / backend / capacity change |
| `hi.agents.{host}.lemonade.deleted` | Proposed deployment controller through Hermes | Argus, Telemachy | Instance removed |
| `hi.logs.lemonade.{host}` | Lemonade sidecar | Argus/Loki | Structured serving logs |
| Prometheus scrape (metrics) | Lemonade exporter | Argus | TTFT, throughput, tokens/s, model-loaded, RPC worker count |

These would reuse the existing `hi.agents.{host}.{name}.*` grammar
([nats-subjects.md](../nats-subjects.md)) and the `hi.logs.>` namespace—no new
top-level namespace is proposed. Hermes currently routes supported inbound
webhook events; it does not discover or register Lemonade instances. An
implemented deployment controller would own lifecycle observation and submit
schema-valid events through Hermes's authenticated webhook boundary. Metrics
would be scraped into Argus only after the exporter and dashboard changes land.

### 3. Client wiring

- **OpenAI-compatible clients** — Scylla judges, Hephaestus/skill-level LLM
  calls, and any future OpenHands-style lane — point `base_url` at the lane
  (`http://lemonade:13305/api/v1`) with the lane's API key; no code forks.
- **Claude Code myrmidons** remain on Anthropic by default. The lane is an
  opt-in alternative for open-weight workloads, never a silent downgrade of
  the primary agent lane.
- **Odyssey**: trained checkpoints export to ONNX via the in-repo exporter
  (`src/odyssey/export/`, opset 14 — all AlexNet-CIFAR10 ops are supported)
  and are served from the lane, closing the train → serve loop in-org.
  GGUF is reserved for future transformer checkpoints; a CNN has no servable
  GGUF/llama.cpp path.
- **Scylla** gains a local-vs-cloud ablation axis (same prompt, local
  open-weight vs cloud Claude judge) on its T0–T6 tiers.

### 4. Proposed ADR-013 alignment

Lemonade is a **serving sidecar — compute substrate, not orchestration**. The
ADR-013 principle that *LLM work never runs inside the C++ services*
(Nestor, Agamemnon, Keystone) is **unchanged**: those services never invoke
models directly, in-process or via the lane. LLM work continues to happen in
agent processes (myrmidons, judges, skills), which call the lane over REST the
same way they call any external service. The lane is also **non-gating**: it
is optional infrastructure, and its absence must not block the pipeline (the
Claude cloud lane remains the default path).

## Consequences

**Positive:**

- **Privacy and sovereignty**: prompts and completions for open-weight
  workloads never leave the mesh; org-trained models can be served from
  in-org hardware.
- **Latency and cost**: an unverified historical spike report estimated about
  35 ms TTFT and 51 tok/s on a 2015-era 4-core CPU with no marginal per-token
  charge. Those figures are not current evidence and must be reproduced before
  use in an operational comparison.
- **Closes the train → serve loop**: Odyssey checkpoints gain a real
  deployment path (ONNX) instead of dying in `weights/` directories.
- **New capabilities**: TTS/STT (whisper.cpp, Kokoro) can upgrade the
  interview relay (`hi.pipeline.interview.*`) to voice; Scylla gains a
  local-vs-cloud ablation axis.
- **Additive, not invasive**: no component is replaced; the Anthropic lane is
  untouched for Claude workloads.

**Negative:**

- **Open-weight quality gap** for complex agentic work — the lane is not a
  drop-in for architect-level myrmidons. Mitigation: Claude remains the
  default agent lane; the lane is opt-in per workload.
- **Lemonade's ONNX Runtime backend is text-classification-only today** —
  vision CNNs (AlexNet-CIFAR10) cannot be served through Lemonade itself;
  they require a separate ONNX Runtime sidecar vessel. The `.onnx` artifact
  is Lane-ready regardless, so this closes as Lemonade adds generic ONNX
  serving.
- **Hardware heterogeneity**: no retained evidence proves an active GPU, NPU,
  or RPC-pooling serving path. The historical report says a GTX 1080 is
  installed but unused by the tested image; AMD NPU and multi-node RPC
  capacity remain future work.
- **Third-party-maintained image**: digest pins and release tracking are
  required (upstream is community/AMD-managed, not in-org).
- **Security hygiene burden**: an unauthenticated or wide-open instance is a
  privacy risk. `LEMONADE_API_KEY` plus an explicit loopback or
  operator-approved private bind is mandatory; activation also requires live
  firewall and reachability readback because static validation cannot prove
  the effective host exposure (the vessel defaults to no auth).

**Neutral:**

- New NATS subjects live under the existing `hi.agents.>` / `hi.logs.>`
  namespaces; no subject-schema migration.
- Adding the lane follows the standard add-a-component process: AchaeanFleet
  vessel → Myrmidons manifest → Hermes registration → Argus dashboard → this
  ADR's inventory entries.
- The Anthropic API key remains required for the primary lane; the fleet now
  carries two inference paths instead of one.

## Addendum (2026-08-12): Router policies (`collection.router`)

Lemonade's **Router** ([Router Policies](https://lemonade-server.ai/docs/dev/router-policy/))
is an in-process, per-request **model-selection engine** — not an API gateway,
reverse proxy, load balancer, or message router. A `collection.router` policy
is registered like any collection (`POST /v1/pull`); pointing the OpenAI
`model` field at the collection's name triggers the routing engine, which
evaluates rules top-to-bottom (first match wins, `default_model` fallback)
and selects a candidate model per request.

- **Conditions**: deterministic (`keywords_any`/`keywords_all`, `regex`,
  `min_chars`/`max_chars`, `has_tools`/`has_images`, `metadata`) and
  model-backed (`semantic_similarity`, `classifier` via `/v1/classify`, or
  `llm`-as-classifier). An `routing.router` block replaces authored rules with
  an LLM picking the candidate itself.
- **Candidates**: any registered component — local GGUF/ONNX models or
  `cloud`-recipe models from an installed and authenticated provider (e.g.
  Fireworks). A policy can keep `consent: denied` requests local while heavy
  work routes to the cloud; the split is entirely policy-driven.
- **Observability**: every routed response carries an `x-lemonade-route`
  header (matched rule id or `default`); with `"route_trace": true` the body
  (or first SSE event when streaming) carries the full decision trace — a
  natural fit for the fleet's runnable-evidence posture (ADR-014).

**Placement in the mesh**: the Router is a **feature of the ADR-019 lane, not
a replacement for any fleet component**. It replaces nothing today: it absorbs
the role of *client-side* per-request model selection (no fleet client has
written that logic yet), keeping model-choice policy server-side. It does not
overlap NATS routing, Hermes message delivery, Agamemnon planning, or Keystone
task dispatch — those operate at the infrastructure/event layer, while the
Router selects a model within a single Lemonade instance. This proposal keeps
LLM execution outside the pinned C++ services: router policies are authored
configuration, and the lane remains non-gating with the Anthropic lane as
default. Proposed ADR-013 describes the related future mesh boundary.

## References

- [Router Policies (`collection.router`)](https://lemonade-server.ai/docs/dev/router-policy/) —
  model-selection engine (addendum 2026-08-12)
- [ADR-001](001-podman-over-docker.md) — podman as the container runtime
- [ADR-005](005-nats-subject-schema.md) — NATS subject schema (extended here)
- [ADR-008](008-nats-tls-encryption.md) / [ADR-009](009-nats-authentication.md)
  / [ADR-010](010-nats-mtls-subject-scoped-auth.md) — transport security for
  the new lifecycle events
- [ADR-013](013-hmas-mesh-wire-contracts.md) — proposed wire contracts and
  future LLM execution boundary
- [ADR-014](014-runnable-evidence-for-metric-claims.md) — proposed runnable
  evidence design related to the recorded spike numbers
- [`AGENTS.md`](../../AGENTS.md) — binding repository evidence-integrity policy
- [architecture.md](../architecture.md) — component inventory and network
  topology
- [nats-subjects.md](../nats-subjects.md) — `hi.agents.{host}.{name}.*` grammar
- [Lemonade docs](https://lemonade-server.ai/docs/) /
  [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) —
  container image, API, backends
- Historical spike report: 2026-08-12 epimetheus session using
  `ghcr.io/lemonade-sdk/lemonade-server`, `Qwen3-0.6B-GGUF`,
  `--network=host`, and `LEMONADE_API_KEY`. Its commands were described as
  session-local `/tmp/lemonade-*` scripts; no retained output or independent
  re-execution receipt is available, so the report carries no evidentiary
  weight for completion or deployment.
