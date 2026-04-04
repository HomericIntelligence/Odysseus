#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Metrics Helpers
# Wraps curl against Prometheus exporter at :9100

METRICS_PORT="${METRICS_PORT:-9100}"
METRICS_URL="http://localhost:${METRICS_PORT}"

metrics_get() {
    curl -sf "${METRICS_URL}/metrics" 2>/dev/null
}

# Assert a Prometheus metric has a specific value
# Usage: metrics_assert_gauge "hi_agamemnon_health" "1"
metrics_assert_gauge() {
    local metric_name="$1" expected="$2"
    local metrics
    metrics=$(metrics_get) || return 1
    echo "$metrics" | grep -q "${metric_name} ${expected}"
}

# Check if a metric exists (any value)
metrics_exists() {
    local metric_name="$1"
    local metrics
    metrics=$(metrics_get) || return 1
    echo "$metrics" | grep -q "${metric_name}"
}
