# Runbook: SLO Alerting Rules

Deploy and maintain the SLO alert rules for the HomericIntelligence agent mesh
in Argus. This runbook covers the Tier 1 (measurable today) alert rules
only — Tier 2 rules are blocked until instrumentation lands per ADR-012.

See [ADR-012](../adr/012-slo-sla-definitions.md) for the full SLO definitions,
the measurable-vs-instrumentation-required split, and the review cadence.

---

## Alert rule file

**File:** `infrastructure/Argus/rules/slo_alerts.yml`

**Auto-load:** Prometheus loads all files matching `/etc/prometheus/rules/*.yml`
at startup (configured via `docker-compose.yml` volume mount and
`configs/prometheus.yml` rule-file glob). No Prometheus config change is
required — creating `slo_alerts.yml` in the `rules/` directory is sufficient.

**Style reference:** `infrastructure/Argus/rules/agent-alerts.yml`

---

## Step 1 — Reconcile metric names against the Argus exporter

Before deploying any alert rule, confirm that every metric used in an active
(non-commented) rule is emitted by the exporter. Run this grep from the
Odysseus repo root:

```bash
grep -rhoE "hi_[a-z_]+|homeric_[a-z_]+" \
  infrastructure/Argus/rules/ \
  infrastructure/Argus/exporter/ \
  | sort -u
```

Every metric name used in an uncommented `expr:` in `slo_alerts.yml` must
appear in the output. If a metric name is absent, the alert expression will
match nothing and never fire — move the rule to the BLOCKED section.

---

## Step 2 — Create `slo_alerts.yml`

Create `infrastructure/Argus/rules/slo_alerts.yml` with the following
content. **Do not uncomment the BLOCKED section** until the corresponding
histogram metric is confirmed emitted by the Argus exporter.

```yaml
groups:
  - name: slo_alerts
    rules:
      # ---------------------------------------------------------------
      # Tier 1: SLIs measurable today (real hi_* / up metrics)
      # ---------------------------------------------------------------

      # Availability SLO — 99.5%/month per core service.
      # Alert when Agamemnon health gauge drops to 0 for 2+ minutes.
      - alert: SLOAgamemnonAvailability
        expr: hi_agamemnon_health == 0
        for: 2m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "Agamemnon availability SLO at risk (service down)"
          description: >
            hi_agamemnon_health has been 0 for at least 2m.
            Monthly error budget: 3 h 39 m. Open the disaster-recovery runbook.

      # Alert when Nestor health gauge drops to 0 for 2+ minutes.
      - alert: SLONestorAvailability
        expr: hi_nestor_health == 0
        for: 2m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "Nestor availability SLO at risk (service down)"
          description: >
            hi_nestor_health has been 0 for at least 2m.
            Monthly error budget: 3 h 39 m. Open the disaster-recovery runbook.

      # Alert when the Argus exporter scrape target is unreachable.
      # A down exporter makes all other SLI measurements unreliable.
      - alert: SLOExporterAvailability
        expr: up{job="homeric-exporter"} == 0
        for: 2m
        labels:
          severity: critical
          slo: availability
        annotations:
          summary: "Argus exporter down — availability SLO unmeasurable"
          description: >
            Prometheus cannot scrape the homeric-exporter target.
            All hi_* SLI metrics are stale until the exporter recovers.

      # Task success SLO — failure ratio < 5% sustained over 15 minutes.
      - alert: SLOTaskFailureRatio
        expr: >
          (hi_tasks_by_status{status="failed"} / (hi_tasks_total + 1e-9))
          > 0.05
        for: 15m
        labels:
          severity: warning
          slo: task_success
        annotations:
          summary: >
            Task failure ratio above 5% SLO
            ({{ $value | humanizePercentage }})
          description: >
            The ratio hi_tasks_by_status{status="failed"} /
            hi_tasks_total has exceeded 5% for 15 minutes.
            The existing AgentFailureRate alert fires at 20%; this rule
            provides earlier warning at the SLO threshold.

      # Metrics freshness SLO — exporter scrape data must be < 5 minutes old.
      # Stale data causes all SLI measurements to lag or miss incidents.
      - alert: SLOScrapeFreshness
        expr: (time() - homeric_exporter_scrape_timestamp) > 300
        for: 5m
        labels:
          severity: warning
          slo: freshness
        annotations:
          summary: "Metrics stale >5 min — SLO measurements unreliable"
          description: >
            homeric_exporter_scrape_timestamp is more than 300 s behind
            wall clock. All SLI alert expressions are operating on stale
            data. Check the Argus exporter logs.

      # ---------------------------------------------------------------
      # Tier 2: BLOCKED — requires instrumentation that does not yet
      # exist in Argus. DO NOT uncomment until the named metric
      # is confirmed emitted by the exporter (see ADR-012, Tier 2 table).
      # ---------------------------------------------------------------

      # BLOCKED: requires hi_nats_event_duration_seconds histogram
      # (Hermes or Keystone must emit it; ADR-012).
      # Target: P95 < 25 ms, P99 < 50 ms.
      #
      # - alert: SLONatsEventLatencyP95
      #   expr: >
      #     histogram_quantile(
      #       0.95,
      #       sum(rate(hi_nats_event_duration_seconds_bucket[5m])) by (le)
      #     ) > 0.025
      #   for: 10m
      #   labels: { severity: warning, slo: nats_event_latency }
      #   annotations:
      #     summary: "NATS event latency P95 above 25 ms SLO"
      #
      # - alert: SLONatsEventLatencyP99
      #   expr: >
      #     histogram_quantile(
      #       0.99,
      #       sum(rate(hi_nats_event_duration_seconds_bucket[5m])) by (le)
      #     ) > 0.05
      #   for: 10m
      #   labels: { severity: warning, slo: nats_event_latency }
      #   annotations:
      #     summary: "NATS event latency P99 above 50 ms SLO"

      # BLOCKED: requires hi_nats_reconnect_duration_seconds histogram
      # (same emitter requirement as above; ADR-012).
      # Target: P99 < 5 s.
      #
      # - alert: SLONatsReconnectP99
      #   expr: >
      #     histogram_quantile(
      #       0.99,
      #       sum(rate(hi_nats_reconnect_duration_seconds_bucket[5m])) by (le)
      #     ) > 5
      #   for: 5m
      #   labels: { severity: warning, slo: nats_reconnect_time }
      #   annotations:
      #     summary: "NATS reconnect time P99 above 5 s SLO"

      # BLOCKED: requires hi_tasks_completed_total monotonic counter
      # (hi_tasks_total is a gauge; rate() on a gauge is unsafe; ADR-012).
      # Target: >= 100 tasks/min sustained; warn at < 80%.
      #
      # - alert: SLOAgamemnonThroughput
      #   expr: sum(rate(hi_tasks_completed_total[5m])) * 60 < 80
      #   for: 10m
      #   labels: { severity: warning, slo: throughput }
      #   annotations:
      #     summary: >
      #       Agamemnon throughput below 80% of 100 tasks/min SLO
      #       ({{ $value | humanize }} tasks/min)
```

---

## Step 3 — Validate the rule file

Before reloading Prometheus, check the rule file syntax with `promtool`:

```bash
cd infrastructure/Argus
promtool check rules rules/slo_alerts.yml
```

Expected output:

```
Checking rules/slo_alerts.yml
  SUCCESS: 5 rules found
```

(5 active rules: SLOAgamemnonAvailability, SLONestorAvailability,
SLOExporterAvailability, SLOTaskFailureRatio, SLOScrapeFreshness.)

---

## Step 4 — Reload Prometheus

If the Argus stack is already running, reload Prometheus without restarting:

```bash
curl -X POST http://localhost:9090/-/reload
```

The `POST /-/reload` endpoint only works if Prometheus was started with the
`--web.enable-lifecycle` flag (set in Argus's `docker-compose.yml`). If
that flag is not enabled, the endpoint returns HTTP 405 — in that case, restart
the Argus stack instead. Alternatively, restart the Argus stack:

```bash
podman compose -f infrastructure/Argus/docker-compose.yml restart prometheus
```

Verify the rules loaded:

```bash
curl -s http://localhost:9090/api/v1/rules \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data['data']['groups']:
    if g['name'] == 'slo_alerts':
        for r in g['rules']:
            print(r['name'])
"
```

Expected output (Tier 1 rules only):

```
SLOAgamemnonAvailability
SLONestorAvailability
SLOExporterAvailability
SLOTaskFailureRatio
SLOScrapeFreshness
```

---

## Step 5 — Unblocking a Tier 2 rule

When a Tier 2 metric becomes available (e.g., `hi_nats_event_duration_seconds`
is confirmed emitted by the exporter):

1. Run the reconciliation grep from Step 1 and confirm the metric appears.
2. Uncomment the corresponding alert rule block in `slo_alerts.yml`.
3. Validate with `promtool check rules rules/slo_alerts.yml`.
4. Reload Prometheus (Step 4).
5. Update [ADR-012](../adr/012-slo-sla-definitions.md) with a note that the
   SLI has moved from Tier 2 to Tier 1 (or create a superseding ADR if the
   numeric target changes).

---

## Troubleshooting

**Alert never fires despite the condition being true.**
Run the reconciliation grep (Step 1). If the metric is absent, the `expr:`
evaluates to an empty result set and the alert will never transition to
`firing`. Move the rule to the BLOCKED section until the metric is emitted.

**`promtool check rules` fails with "unknown metric".**
`promtool check rules` validates syntax, not metric existence. The "unknown
metric" error indicates a PromQL parse failure (e.g., a mismatched `{}`).
Check the YAML indentation — the `expr:` value with `>` block scalar must be
dedented consistently.

**Prometheus reports "no rule files found".**
Confirm the `rules/` directory is mounted at `/etc/prometheus/rules/` in
`docker-compose.yml` and that `configs/prometheus.yml` contains
`rule_files: ['/etc/prometheus/rules/*.yml']`. Check with:
```bash
curl -s http://localhost:9090/api/v1/rules | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['data']['groups'])"
```

---

## See also

- [ADR-012](../adr/012-slo-sla-definitions.md) — SLO/SLA definitions,
  metric reconciliation, and review cadence
- `infrastructure/Argus/rules/agent-alerts.yml` — existing alert style
  reference
- `infrastructure/Argus/rules/recording-rules.yml` — recording rules
  including `hi:tasks_failure_rate:avg`
- [runbooks/disaster-recovery.md](disaster-recovery.md) — incident response
  when availability SLO alerts fire
- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
