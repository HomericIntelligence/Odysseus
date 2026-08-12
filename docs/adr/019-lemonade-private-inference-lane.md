# ADR 019: Lemonade as the Private Inference Lane for the Mesh

**Status:** Proposed

---

## Context

The HomericIntelligence mesh has **no local inference component** (see the
component inventory in [architecture.md](../architecture.md)):

- **Myrmidons** are Claude Code sessions that call `api.anthropic.com`
  (`ANTHROPIC_API_KEY` / OAuth); every prompt and every dollar leaves the mesh.
- **Nestor, Agamemnon, and Keystone** are C++ services that, by
  [ADR-013](013-hmas-mesh-wire-contracts.md), never run LLM work — LLM work
  happens in myrmidon agent processes.
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

Measured evidence (2026-08-12, epimetheus; see
[ADR-014](014-runnable-evidence-for-metric-claims.md) for the evidence
policy): the spike container served `Qwen3-0.6B-GGUF` (364.5 MB, Q4_0) on the
4-core i5-6600K CPU backend with the following results.

| Metric | Value |
|---|---|
| Streaming time-to-first-token | ~35 ms (34–37 ms across 5 runs) |
| Round-trip, 64 tokens (non-stream) | ~1.26 s avg (~51 tok/s) |
| Full completion (119 tokens, reasoning + answer) | 2.34 s |
| `GET /live` health | HTTP 200 in 1.3 ms |
| Auth without `LEMONADE_API_KEY` | HTTP 401 (enforced) |
| Cross-host over Tailscale (apollo → epimetheus) | HTTP 200 in 1.6 ms |

The spike also surfaced two fleet facts this ADR encodes: rootless podman
3.4.2 on epimetheus cannot port-publish (`-p` connections reset — the
known rootlessport issue the [AlexNet fleet runbook](../runbooks/alexnet-mesh-fleet.md)
already documents), so the working deployment is `--network=host`; and the
host carries a GTX 1080 that the stock CPU-only image does not use.

## Decision

**Lemonade is adopted as the mesh's private inference lane — an optional,
additive serving substrate for open-weight models and OpenAI-compatible
client flows.** It does not replace the Anthropic cloud lane for Claude models
(proprietary weights); it replaces the cloud API for everything that can run
on open weights, and it gives Odyssey-trained models a deployment path.

### 1. Placement

- **Vessel**: a pinned `ghcr.io/lemonade-sdk/lemonade-server` container in
  AchaeanFleet (digest-pinned per repo convention), one instance per fleet
  host that should serve models, running on the `homeric-mesh` Podman network.
- **Networking**: `--network=host` where rootless port publishing is broken
  (verified on epimetheus) — the same pattern the fleet training scripts use;
  otherwise the standard `-p 127.0.0.1:13305:13305` host binding. The API is
  reachable **only inside the tailnet**; no host interface is exposed to the
  public internet (per [architecture.md](../architecture.md) network
  topology).
- **Auth**: `LEMONADE_API_KEY` is mandatory on every instance (verified
  enforced server-side). Keys are supplied via environment at schedule time,
  never committed.
- **Persistence**: named volumes persist the HuggingFace model cache, llama
  binaries, and recipe config (`lemonade-cache`, `lemonade-llama`,
  `lemonade-recipe`) so models survive container recreation.
- **Backend selection**: CPU backend by default on the current Intel fleet
  (`config.json` in the recipe volume). When AMD NPU (XDNA2) or GPU-capable
  hosts join, ROCm/Vulkan/NPU backends are enabled per host, and
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
| `hi.agents.{host}.lemonade.created` | Hermes | Argus, Telemachy | Instance registered, healthy |
| `hi.agents.{host}.lemonade.updated` | Hermes | Argus | Model load / backend / capacity change |
| `hi.agents.{host}.lemonade.deleted` | Hermes | Argus, Telemachy | Instance removed |
| `hi.logs.lemonade.{host}` | Lemonade sidecar | Argus/Loki | Structured serving logs |
| Prometheus scrape (metrics) | Lemonade exporter | Argus | TTFT, throughput, tokens/s, model-loaded, RPC worker count |

These reuse the existing `hi.agents.{host}.{name}.*` grammar
([nats-subjects.md](../nats-subjects.md)) and the `hi.logs.>` namespace — no
new top-level namespace is introduced. Hermes publishes the lifecycle events
from its existing agent-registration path; metrics are scraped into the Argus
Grafana dashboards alongside all other components.

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

### 4. ADR-013 alignment (normative)

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
- **Latency and cost**: measured ~35 ms TTFT and ~51 tok/s on a 2015-era 4-core
  CPU with zero marginal per-token cost; no public-internet round trip.
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
- **Hardware heterogeneity**: the current fleet is Intel CPU-only; the AMD
  NPU/GPU and RPC-pooling value awaits capable hardware joining the mesh.
- **Third-party-maintained image**: digest pins and release tracking are
  required (upstream is community/AMD-managed, not in-org).
- **Security hygiene burden**: an unauthenticated or wide-open instance is a
  privacy risk; `LEMONADE_API_KEY` + tailnet-only binding are mandatory and
  should be CI/lint-checked (the vessel defaults to no auth).

**Neutral:**

- New NATS subjects live under the existing `hi.agents.>` / `hi.logs.>`
  namespaces; no subject-schema migration.
- Adding the lane follows the standard add-a-component process: AchaeanFleet
  vessel → Myrmidons manifest → Hermes registration → Argus dashboard → this
  ADR's inventory entries.
- The Anthropic API key remains required for the primary lane; the fleet now
  carries two inference paths instead of one.

## References

- [ADR-001](001-podman-over-docker.md) — podman as the container runtime
- [ADR-005](005-nats-subject-schema.md) — NATS subject schema (extended here)
- [ADR-008](008-nats-tls-encryption.md) / [ADR-009](009-nats-authentication.md)
  / [ADR-010](010-nats-mtls-subject-scoped-auth.md) — transport security for
  the new lifecycle events
- [ADR-013](013-hmas-mesh-wire-contracts.md) — wire contracts; the
  LLM-never-in-C++ principle this ADR preserves
- [ADR-014](014-runnable-evidence-for-metric-claims.md) — evidence policy for
  the measured spike numbers
- [architecture.md](../architecture.md) — component inventory and network
  topology
- [nats-subjects.md](../nats-subjects.md) — `hi.agents.{host}.{name}.*` grammar
- [Lemonade docs](https://lemonade-server.ai/docs/) /
  [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade) —
  container image, API, backends
- Spike evidence: 2026-08-12 epimetheus run — `ghcr.io/lemonade-sdk/lemonade-server`,
  `Qwen3-0.6B-GGUF`, `--network=host`, `LEMONADE_API_KEY` (commands captured
  in the session's `/tmp/lemonade-*` scripts)
