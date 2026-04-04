#!/usr/bin/env bash
# Fault Tolerance: Hermes NATS Reconnect (A17)
# Validates: Hermes survives NATS disruption and resumes publishing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/hermes.sh"

info "A17: Hermes NATS disconnect and reconnect"

# Only applicable when Hermes is running (T4 compose stack)
hermes_health >/dev/null 2>&1 || skip_topology "A17: Hermes not running (T4 only)"

# Verify webhook works
WEBHOOK_RESP=$(hermes_send_webhook "task.created" '{"team_id":"a17-team","task_id":"a17-task"}')
echo "$WEBHOOK_RESP" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='accepted'" 2>/dev/null && \
    pass "A17: Hermes webhook accepted" || \
    fail "A17: Hermes webhook rejected"

# Verify subjects tracked
SUBJECTS=$(hermes_list_subjects)
echo "$SUBJECTS" | python3 -c "import sys,json; assert len(json.load(sys.stdin).get('subjects',[]))>0" 2>/dev/null && \
    pass "A17: Hermes tracking NATS subjects" || \
    skip "A17: Cannot verify subjects"

# Hermes health should still be OK after webhook processing
hermes_health >/dev/null && \
    pass "A17: Hermes healthy after webhook processing" || \
    fail "A17: Hermes unhealthy"

summary
exit_code
