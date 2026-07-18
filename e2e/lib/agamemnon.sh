#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Agamemnon REST Helpers

AGAMEMNON_PORT="${AGAMEMNON_PORT:-8080}"
AGAMEMNON_URL="http://localhost:${AGAMEMNON_PORT}"

# Agamemnon refuses to start without AGAMEMNON_API_KEY (server_main.cpp) and, once
# set, enforces it on every non-exempt /v1/* endpoint (auth.cpp / routes.cpp).
# start_agamemnon_bg (process.sh) launches the server with this same value, so the
# harness's requests must carry it. Health/version are exempt; sending the header
# there is harmless.
AGAMEMNON_API_KEY="${AGAMEMNON_API_KEY:-e2e-test-key}"
# curl args that add the API key header; expand as "${AGAMEMNON_AUTH[@]}".
AGAMEMNON_AUTH=(-H "X-API-Key: ${AGAMEMNON_API_KEY}")

# ─── Health ──────────────────────────────────────────────────────────────────

agamemnon_health() {
    curl -sf "${AGAMEMNON_URL}/v1/health" 2>/dev/null "${AGAMEMNON_AUTH[@]}"
}

agamemnon_wait_healthy() {
    local max="${1:-30}"
    wait_for "${AGAMEMNON_URL}/v1/health" "Agamemnon" "$max"
}

# ─── Agents ──────────────────────────────────────────────────────────────────

agamemnon_create_agent() {
    local name="${1:-e2e-agent}" label="${2:-E2E Agent}"
    curl -sf -X POST "${AGAMEMNON_URL}/v1/agents" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\",\"label\":\"${label}\",\"program\":\"none\",\"workingDirectory\":\"/tmp\",\"taskDescription\":\"E2E test\",\"tags\":[\"e2e\"],\"owner\":\"e2e\",\"role\":\"member\"}"
}

agamemnon_start_agent() {
    local agent_id="$1"
    curl -sf -X POST "${AGAMEMNON_URL}/v1/agents/${agent_id}/start" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: application/json" -d '{}'
}

agamemnon_list_agents() {
    curl -sf "${AGAMEMNON_URL}/v1/agents" 2>/dev/null "${AGAMEMNON_AUTH[@]}"
}

# ─── Teams ───────────────────────────────────────────────────────────────────

agamemnon_create_team() {
    local name="${1:-e2e-team}"
    curl -sf -X POST "${AGAMEMNON_URL}/v1/teams" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\"}"
}

# ─── Tasks ───────────────────────────────────────────────────────────────────

agamemnon_create_task() {
    local team_id="$1" subject="${2:-E2E test task}" task_type="${3:-hello}" agent_id="${4:-}"
    local body="{\"subject\":\"${subject}\",\"description\":\"E2E test\",\"type\":\"${task_type}\""
    [ -n "$agent_id" ] && body="${body},\"assigneeAgentId\":\"${agent_id}\""
    body="${body}}"
    curl -sf -X POST "${AGAMEMNON_URL}/v1/teams/${team_id}/tasks" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d "$body"
}

agamemnon_get_tasks() {
    # limit=1000 (the server's kMaxLimit): GET /v1/tasks paginates at 100 by
    # default and sorts by task UUID, so once a suite run accumulates >100
    # tasks, any task whose UUID sorts past the first page becomes invisible
    # to status polls — it reads as not_found forever and its wait times out.
    # That is exactly what broke B07/B08 fan-out (4/50 "lost", then a hang).
    curl -sf "${AGAMEMNON_URL}/v1/tasks?limit=1000" 2>/dev/null "${AGAMEMNON_AUTH[@]}"
}

agamemnon_get_task_status() {
    local task_id="$1"
    local tasks
    tasks=$(agamemnon_get_tasks) || return 1
    echo "$tasks" | python3 -c "
import sys, json
tasks = json.load(sys.stdin).get('tasks', [])
match = [t for t in tasks if t.get('id') == '${task_id}']
print(match[0].get('status', 'unknown') if match else 'not_found')
"
}

# Count how many of the given task ids ($@) are "completed" — ONE task-list
# fetch per call, so batch waiters (fan-out) poll in O(1) requests instead of
# one request per task. Prints the count; returns 1 if the list fetch fails.
agamemnon_count_completed() {
    local tasks
    tasks=$(agamemnon_get_tasks) || { echo 0; return 1; }
    echo "$tasks" | python3 -c "
import sys, json
ids = set(sys.argv[1:])
tasks = json.load(sys.stdin).get('tasks', [])
print(sum(1 for t in tasks if t.get('id') in ids and t.get('status') == 'completed'))
" "$@"
}

# Wait for a task to reach "completed" status. Returns 0 on success, 1 on timeout.
agamemnon_wait_task_completed() {
    local task_id="$1" max="${2:-30}" elapsed=0 status
    while [ "$elapsed" -lt "$max" ]; do
        status=$(agamemnon_get_task_status "$task_id" 2>/dev/null)
        [ "$status" = "completed" ] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# ─── Full Task Lifecycle ─────────────────────────────────────────────────────

# Runs the complete task lifecycle: create agent → start → create team → create task → wait complete.
# Exports: IPC_AGENT_ID, IPC_TEAM_ID, IPC_TASK_ID
# Returns 0 on success, 1 on failure.
run_task_lifecycle() {
    local task_type="${1:-hello}" timeout="${2:-30}"

    # Create agent
    local agent_resp
    agent_resp=$(agamemnon_create_agent "ipc-worker-$(date +%s)" "IPC Worker") || return 1
    IPC_AGENT_ID=$(echo "$agent_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
    [ -z "$IPC_AGENT_ID" ] || [ "$IPC_AGENT_ID" = "None" ] && return 1

    # Start agent
    agamemnon_start_agent "$IPC_AGENT_ID" >/dev/null || return 1

    # Create team
    local team_resp
    team_resp=$(agamemnon_create_team "ipc-team-$(date +%s)") || return 1
    IPC_TEAM_ID=$(echo "$team_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")
    [ -z "$IPC_TEAM_ID" ] || [ "$IPC_TEAM_ID" = "None" ] && return 1

    # Create task
    local task_resp
    task_resp=$(agamemnon_create_task "$IPC_TEAM_ID" "IPC test task" "$task_type" "$IPC_AGENT_ID") || return 1
    IPC_TASK_ID=$(echo "$task_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")
    [ -z "$IPC_TASK_ID" ] || [ "$IPC_TASK_ID" = "None" ] && return 1

    # Wait for completion
    agamemnon_wait_task_completed "$IPC_TASK_ID" "$timeout"
}

# ─── Chaos API ───────────────────────────────────────────────────────────────

agamemnon_inject_fault() {
    local fault_type="$1"
    curl -sf -X POST "${AGAMEMNON_URL}/v1/chaos/${fault_type}" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: application/json" -d '{}'
}

agamemnon_remove_fault() {
    local fault_id="$1"
    curl -sf -X DELETE "${AGAMEMNON_URL}/v1/chaos/${fault_id}" "${AGAMEMNON_AUTH[@]}"
}

agamemnon_list_faults() {
    curl -sf "${AGAMEMNON_URL}/v1/chaos" 2>/dev/null "${AGAMEMNON_AUTH[@]}"
}

# ─── Raw POST (for security/malformed tests) ─────────────────────────────────

agamemnon_raw_post() {
    local path="$1" body="$2" content_type="${3:-application/json}"
    curl -s -o /dev/null -w "%{http_code}" -X POST "${AGAMEMNON_URL}${path}" \
        "${AGAMEMNON_AUTH[@]}" \
        -H "Content-Type: ${content_type}" \
        --max-time 10 \
        -d "$body" 2>/dev/null || echo "000"
}
