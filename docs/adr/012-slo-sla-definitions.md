# ADR 012: Define SLO/SLA Targets for the Agent Mesh

**Status:** Proposed

---

## Context

The HomericIntelligence distributed agent mesh has no documented Service Level
Objectives (SLOs) or Service Level Agreements (SLAs) anywhere in `docs/`,
`configs/`, or any prior ADR. Without SLOs there is no baseline for alerting
thresholds, capacity planning, or incident response triage (see issue #185,
parent issue #174).

**Important caveat — targets are unvalidated initial proposals.** The numeric
targets below represent initial engineering proposals, not validated production
measurements. Only the availability and task-success SLIs are measurable
today with metrics ProjectArgus already emits (`hi_*` gauges, `up`). The
latency, reconnect, and throughput SLIs have no backing metric at all — they
are recorded here as targets-with-prerequisites so instrumentation work has a
clear specification, not as active guarantees.

**The single empirical anchor** available at time of writing is the e2e
walkthrough's measured Hermes webhook latency: P50=1 ms, P95=3 ms
(`docs/e2e-walkthrough-report.md`, benchmark section). The NATS event latency
SLO target (P95 < 25 ms) is derived from this measurement: set comfortably
above the measured P95 to allow for message-queue overhead while still
excluding tail-latency regressions. All other numeric targets are set from
operational convention (e.g., the 99.5% availability budget is a standard
"two-nines-and-a-half" figure for non-critical infrastructure) and must be
revisited once the mesh has production traffic data.

**Metric reconciliation.** Every SLI in the "measurable today" table was
reconciled against the checked-out ProjectArgus submodule
(`infrastructure/ProjectArgus/exporter/exporter.py`, `rules/`). The exporter
emits only gauges via a `gauge()` helper — there are no histograms today. The
"requires instrumentation" table documents the exact metric name and histogram
bucket specification that a future emitter must use.

## Decision

SLO targets are split into two tiers based on whether the backing metric
already exists.

### Tier 1 — SLIs measurable today

These SLIs use metrics that ProjectArgus already emits and can be alerted on
immediately.

| SLI | Metric (verified in Argus) | SLO proposal | Evidence / source |
|-----|----------------------------|--------------|-------------------|
| Service availability — Agamemnon | `hi_agamemnon_health` (1 = up, 0 = down) | 99.5% monthly (≈ 3 h 39 m error budget/mo) | `exporter/exporter.py`; `rules/agent-alerts.yml` |
| Service availability — Nestor | `hi_nestor_health` (1 = up, 0 = down) | 99.5% monthly | `exporter/exporter.py`; `rules/agent-alerts.yml` |
| Exporter availability | `up{job="homeric-exporter"}` (1 = scrape OK) | 99.5% monthly | Prometheus built-in |
| Task success rate | `hi_tasks_by_status{status="failed"} / (hi_tasks_total + 1e-9)` | failure ratio < 5% sustained (warn); < 20% already alerted in `agent-alerts.yml` | `rules/recording-rules.yml` (`hi:tasks_failure_rate:avg`) |
| Metrics freshness | `time() - homeric_exporter_scrape_timestamp` | < 300 s (stale data makes all SLI measurements unreliable) | `rules/agent-alerts.yml` (`ExporterScrapeStale`) |

### Tier 2 — SLIs requiring instrumentation first

These SLIs have no backing metric in ProjectArgus today. The metric name and
specification below define what a future emitter must expose. Alert rules for
these SLIs are included in `rules/slo_alerts.yml` but are **commented out**
with a `# BLOCKED` header so they cannot silently match nothing.

| SLI | Target metric to emit | Histogram buckets | SLO proposal | Prerequisite |
|-----|-----------------------|-------------------|--------------|--------------|
| NATS event latency (publish → deliver) | `hi_nats_event_duration_seconds` histogram | `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]` | P95 < 25 ms, P99 < 50 ms | ProjectHermes or ProjectKeystone must export this histogram; exporter currently emits gauges only |
| NATS reconnect time | `hi_nats_reconnect_duration_seconds` histogram | same as above | P99 < 5 s | same — not yet emitted |
| Agamemnon task throughput | `hi_tasks_completed_total` monotonic counter (for `rate()`) | n/a (counter) | ≥ 100 tasks/min sustained; warn at < 80% (80 tasks/min) | `hi_tasks_total` is a gauge today; `rate()` on a gauge is unsafe — a monotonic counter must be added |

### Standard SLI metric set for new emitters

Any new component that must contribute to SLO measurement should expose:

- A monotonic `*_total` counter for every event type that contributes to a
  success-rate SLI.
- A `*_duration_seconds` histogram for every latency SLI, with the bucket
  sequence `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`.
- HTTP endpoints `/metrics` (Prometheus), `/healthz` (liveness), and `/readyz`
  (readiness).

This convention ensures that histogram-quantile alert expressions and
recording rules compose across components without per-component tuning.

### Alert rule location

Active Prometheus alert rules for Tier 1 SLIs live in
`infrastructure/ProjectArgus/rules/slo_alerts.yml`. That directory is
auto-loaded by Prometheus via the `/etc/prometheus/rules/*.yml` glob
(`docker-compose.yml` volume mount). See the deployment runbook in
[runbooks/slo-alerting-rules.md](../runbooks/slo-alerting-rules.md).

### Review cadence

SLO targets must be reviewed when:

- Any SLI metric transitions from Tier 2 (requires instrumentation) to Tier 1
  (measurable) — the corresponding alert must be uncommented and the numeric
  target validated against observed data.
- A sustained quarter of production traffic is available — numeric targets
  should be replaced with validated percentiles from real traffic.
- A new component joins the mesh that is covered by an existing SLI category.

## Consequences

**Positive:**
- Availability and task-success SLOs are enforceable immediately against real
  `hi_*` metrics already emitted by ProjectArgus — no instrumentation work
  required.
- Latency, reconnect, and throughput SLOs have a clear specification (metric
  name, bucket list, numeric target) for the teams implementing instrumentation,
  so there is no ambiguity about what to emit or what threshold to hit.
- Establishes a baseline for capacity planning and incident triage even before
  all SLIs are measurable.
- The "unvalidated proposals" framing (this ADR's Status: Proposed +
  explicit language in Context) means targets can be superseded by a new ADR
  once real traffic data is available, without treating the initial numbers as
  contractual.

**Negative:**
- Two SLIs (latency, reconnect) and one SLO (throughput counter) cannot be
  measured or alerted on until ProjectHermes/ProjectKeystone/Agamemnon add
  histograms and counters. These are recorded as explicit prerequisites, not
  silent gaps — but they do leave a monitoring blind spot in the short term.
- All numeric targets are unvalidated; they may need significant revision once
  the mesh carries production traffic. Treating them as hard targets before
  validation risks alert fatigue (thresholds too tight) or missed incidents
  (thresholds too loose).

**Neutral:**
- Odysseus documents targets; ProjectArgus implements alert rules. This split
  is consistent with Odysseus's role as a read-mostly coordination hub
  (CLAUDE.md: "Odysseus is read-mostly. Most day-to-day changes happen in the
  individual submodule repos").
- SLO review becomes a recurring operational event, not a one-off task.
- The ADR lifecycle applies: once accepted, this ADR is frozen. Numeric target
  changes require a new superseding ADR.

## References

- [ADR 002](002-nats-event-bridge.md) — NATS JetStream as event bridge;
  mentions SLA metrics in §4
- [ADR 008](008-nats-tls-encryption.md) — ADR style reference
- [Issue #185](https://github.com/HomericIntelligence/Odysseus/issues/185) —
  Finding: no SLO/SLA definitions in the repository
- [Issue #174](https://github.com/HomericIntelligence/Odysseus/issues/174) —
  Parent audit issue
- [docs/e2e-walkthrough-report.md](../e2e-walkthrough-report.md) — Measured
  Hermes webhook latency baseline (P50=1 ms, P95=3 ms) used to anchor the
  NATS event latency target
- [runbooks/slo-alerting-rules.md](../runbooks/slo-alerting-rules.md) — Deployment
  runbook for `infrastructure/ProjectArgus/rules/slo_alerts.yml`
- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Prometheus histogram and summary](https://prometheus.io/docs/practices/histograms/)
