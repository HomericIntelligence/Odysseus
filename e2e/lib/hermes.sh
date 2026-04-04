#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Hermes REST Helpers

HERMES_PORT="${HERMES_PORT:-8085}"
HERMES_URL="http://localhost:${HERMES_PORT}"

hermes_health() {
    curl -sf "${HERMES_URL}/health" 2>/dev/null
}

hermes_wait_healthy() {
    local max="${1:-30}"
    wait_for "${HERMES_URL}/health" "Hermes" "$max"
}

hermes_send_webhook() {
    local event="$1" data="$2"
    local ts
    ts=$(date -u +%FT%TZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    curl -sf -X POST "${HERMES_URL}/webhook" \
        -H "Content-Type: application/json" \
        -d "{\"event\":\"${event}\",\"data\":${data},\"timestamp\":\"${ts}\"}"
}

hermes_list_subjects() {
    curl -sf "${HERMES_URL}/subjects" 2>/dev/null
}
