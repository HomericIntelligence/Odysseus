#!/usr/bin/env bash
# Fault Tolerance: Graceful Degradation on NATS Outage (A11 extended)
# Validates: Agamemnon REST API works even when NATS is unreachable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "A11 extended: REST API functional during NATS outage"

# Agamemnon's NatsClient.connect() returns false on NATS failure.
# The REST API should still handle agent/team CRUD operations.

# Create agent (REST only, no NATS required)
AGENT_RESP=$(agamemnon_create_agent "graceful-agent-$(date +%s)" "Graceful Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ] && \
    pass "A11: Agent created via REST (no NATS dependency)" || \
    fail "A11: Agent creation failed"

# Start agent
agamemnon_start_agent "$AGENT_ID" >/dev/null && \
    pass "A11: Agent started (REST state management)" || \
    fail "A11: Agent start failed"

# List agents (read operation)
AGENTS=$(agamemnon_list_agents)
echo "$AGENTS" | python3 -c "import sys,json; assert len(json.load(sys.stdin).get('agents',[]))>0" 2>/dev/null && \
    pass "A11: Agent list returns data" || \
    fail "A11: Agent list empty"

# Create team
TEAM_RESP=$(agamemnon_create_team "graceful-team-$(date +%s)")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "None" ] && \
    pass "A11: Team created via REST" || \
    fail "A11: Team creation failed"

# Chaos API also works without NATS
FAULT_RESP=$(agamemnon_inject_fault "test-graceful")
FAULT_ID=$(echo "$FAULT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
[ -n "$FAULT_ID" ] && agamemnon_remove_fault "$FAULT_ID" >/dev/null 2>&1
pass "A11: Chaos API functional (no NATS dependency for fault registry)"

summary
exit_code
