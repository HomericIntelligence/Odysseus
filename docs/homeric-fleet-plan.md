# Homeric Fleet implementation plan

Updated: 2026-09-11. Status: consolidated implementation plan; acceptance has not run.

This plan integrates the laptop/SSH/Slurm operational requirements with the
[Odysseus architecture](architecture.md) and the subsequently approved Fleet
design. It describes implementation to deliver, not capabilities already present.
Accepted ADRs remain unchanged; architectural extensions require new Proposed ADRs
and the existing repository review process.

The initial [web application](../web/README.md) now implements ownership views,
observed message flow, scoped session controls, and private approval/question
forms. It is one integration slice;
the acceptance target and remaining phases below still apply.

## 1. Required outcome

Extend HomericIntelligence into Homeric Fleet using its existing component
boundaries. Interactive operation and automated issue work have equal priority.
The required demonstration is **108 logical agents concurrently doing real,
admitted HomericIntelligence issue work: 12 on this laptop, 48 on M1, and 48 on M2**.
Queued or idle conversations do not count.

Use five managed Codex runtimes: one with 12 independent conversations locally,
and two with 24 conversations on each cluster. Each logical agent has its own
identity, task claim, lease, workspace, permission policy, and conversation.
Sharing a process does not combine task ownership.

Codex is the first supported Fleet provider, pinned initially to **0.153.4**.
Preserve Hephaestus's existing integrations and extension points for later
providers. OMO is a design reference only, with no installation or dependency.
Odyssey remains a standalone research repository that Fleet can work on.

## 2. Component ownership and user flow

| Component | Fleet responsibility |
|---|---|
| Odysseus | Unified web interface for intake, interviews, task trees, workflows, conversations, approvals, agents, allocations, artifacts, health, and dashboards |
| Agamemnon | Planning, delegation, dependencies, durable work state, admission, task claims, allocation reconciliation, recovery decisions, and escalation |
| Nestor | Accept and track research requests; dispatch research Myrmidons; no LLM execution inside the service |
| Telemachy | Describe workflows and register researched work as epics and child issues |
| Keystone | Carry role-addressed work, acknowledgments, lifecycle facts, interviews, and structured events |
| Myrmidons | Desired pools, agent templates, execution policies, and configuration in Git; logical workers claim delegated tasks |
| Hephaestus | Codex adapter, worker supervision, workspaces, issue-stage execution, and build/test offload |
| AchaeanFleet / Proteus | Build, validate, and distribute pinned images and provenance; trigger approved reconciliation |
| Hermes | Bridge GitHub and other external-service events |
| Argus | Collect metrics and logs; provide Odysseus dashboards and alerts |
| Scylla | Define and report reproducible performance experiments |
| Charybdis | Exercise failure and recovery through Agamemnon's chaos interfaces |
| Mnemosyne | Supply task guidance and preserve evidence-backed lessons |

The end-to-end path is:

1. A user submits an idea through Odysseus.
2. Nestor dispatches a research Myrmidon, which interviews the user through Odysseus.
3. Telemachy registers the researched workflow as an epic and child issues.
4. Agamemnon builds the dependency graph and releases eligible work through
   Keystone's role queues after durable admission.
5. An admitted Myrmidon claims one task and reports its identity, generation,
   workspace ownership, and execution host.
6. Hephaestus runs the delegated implementation/review stages and maintains its
   authorized `state:*` labels.
7. Worker facts let Agamemnon update durable state and release dependent work.
8. Progress, interviews, evidence, and observability return to Odysseus.

Already-planned GitHub issues enter through Agamemnon without repeating research.
Interactive sessions use the same admission and workspace ownership controls.
Telemachy does not allocate workers or provide an alternate scheduler.

### Odysseus web application

Continue the React/TypeScript web application alongside the existing terminal
console, with these connected views:

- Research intake and live interviews.
- Agamemnon task/dependency trees linked to work issues, orchestration records,
  pull requests, and the derived GitHub Project board.
- Interactive Codex conversations, approvals, execution evidence, and recovery.
- Pools, workers, Slurm allocations, resource use, queues, drain, and cancellation.
- Workflows, deployments, image provenance, and component health.
- Argus dashboards and Scylla/Charybdis experiments and results.

Every work item must show **who and what is working on it**: the owning component,
logical agent and role, current stage/activity, conversation/execution, worker and
host, pool/allocation, claim generation, last observed activity, and any blocking
dependency or approval. Link these views in both directions: issue to execution,
agent to assigned items, component to its current work, and packet to related item.
Show assignment separately from observed execution. Unknown, stale, disconnected,
idle, and waiting states must remain visible; assignment alone does not mean active.

Provide a live system-flow dashboard covering every component and the laptop/M1/M2
workers. Animate observed application messages (the system's logical packets)
along directed edges, with message/byte rates where measured, pending acknowledgments,
retries, failures, and transport health. Clicking an edge or packet opens its
sanitized trace and associated work item. Filter by component, cluster, item, agent,
message kind, and time window. Configured but unobserved connections appear inactive.

Drive the dashboard from actual Keystone/gateway and supported component observations,
forwarded through the Odysseus backend with SSE or WebSocket cursors. Include event,
message, correlation, task, execution, agent, and generation identifiers where
available; source/destination, observation time, transport, operation, result, and
measured byte count. Keep payload bodies, terminal bytes, prompts, and secrets out
of flow telemetry. Correlate publish/delivery/ack observations without counting
each as a new end-to-end message. Do not invent delivery or network latency from
unsynchronized clocks or unobserved traffic.

Use bounded buffers and explicit sampling/gap indicators under load. Show connection
state and freshness, recover with cursors or a new snapshot after gaps, and stop
animations when observations stop. Observation clients must never pull/ack work
for visualization. Keep high-volume flow observations out of GitHub orchestration
records; Argus owns retained observability. Validate a target of under two seconds
from backend observation to browser rendering under the measured acceptance load.

The browser uses the Odysseus backend, which calls supported component interfaces
and subscribes through Keystone. Bind the initial web service to laptop loopback;
use authenticated browser sessions and validate HTTP/WebSocket origins. Credentials
remain on the backend. The browser receives no SSH keys, Teleport certificates,
OpenBao tokens, or direct worker route.

Provide xterm.js diagnostic terminal attachment and retained output with reconnect
cursors through the backend. Codex app-server messages remain authoritative for
conversation state, approvals, and control. A tmux session, when supported, is a
diagnostic aid and cannot authorize or establish execution state. Terminal bytes
stay in private runtime storage and the attachment channel, outside Keystone
metadata events.

### Laptop service lifecycle

Run `fleetd` as an Agamemnon execution adapter managed by a per-user macOS
LaunchAgent. It owns SSH/Teleport attachment processes, Fleet-secret access,
allocation submission and inspection, and delivery of control messages and worker
facts. Agamemnon owns decisions; `fleetd` has no separate task scheduler or UI.

Operation must survive closing Codex desktop. On adapter restart, hydrate
Agamemnon's desired state, inspect existing allocations and workers, then reconcile
before dispatch. LaunchAgent restart cannot bypass admission, create duplicate
allocations, or start scheduled work outside its window.

## 3. Durable state and public contracts

### What GitHub stores

“GitHub-backed state” means identifiable records with structured orchestration
metadata and links, not Git object internals or terminal transcripts.

| Data | Durable owner/location |
|---|---|
| Requirements, implementation plans, developer discussion | Work-repository issues |
| Research intake identity, creation intent, request digest and work-issue reference | Proposed Nestor GitHub intake metadata namespace; explicit configured repository/branch, distinct from Agamemnon task state |
| Orchestration graph, assignments, claims, generations, admission decisions, and task state | Agamemnon's GitHub-backed records, linked to work issues |
| Implementation and review state labels | Hephaestus-managed GitHub labels |
| Pipeline board | GitHub Project projected from issue-backed state |
| Desired pools, templates, deployment configuration | Myrmidons Git |
| Source changes and reviewed delivery | Work branches, PRs, and checks |
| Conversation history, terminal output, and execution receipts | Private worker/runtime storage |
| Metrics, logs, benchmark artifacts, and SBOMs | Argus and artifact storage, referenced from work records |

For example, a work issue can describe a bug while a linked Agamemnon record holds
its parent/dependencies, assigned logical worker and host, current generation,
command acknowledgment, and recovery decision. The work branch and PR hold the
source change. A receipt reference links to private execution evidence. GitHub
does not hold native Codex authentication or the full conversation.

Add the missing Projects integration as an idempotent, rebuildable projection.
Define explicit mappings from orchestration and Hephaestus stage state to Project
fields. Board edits must not silently become an independent status authority.
Projection failures are visible and retryable without undoing confirmed task state.

Odysseus displays this through the supported Projects health interface. Keep
orchestration state, implementation labels, current session claims, and board
projection health separate. A health read does not refresh the last successful
rebuild. Show missing labels, retained records, multiple claim records, and absent
initial measurements explicitly. The web view cannot write board status or use
it to authorize work.

### Persistence before dispatch

Require a confirmed durable orchestration write before dispatch. Repair existing
paths that mutate in-memory state while merely logging a GitHub write failure.
Fleet rejects memory-only persistence mode and incomplete restart hydration.

Persist command intent, assignment, generation, and idempotency information before
publication. A retry after a publish failure reuses the same durable command.
Restart reconciliation handles publication with an uncertain outcome without
authorizing another execution. Verify cross-record transitions and concurrent
claim behavior; GitHub issue edits are not a transactional database. Fence the
active orchestration writer and validate the supported single-writer/failover
model before allowing replacement execution.

Keep high-volume telemetry and terminal output out of the orchestration records.
Measure GitHub API rate limits and write latency under the proposed control load.
Backpressure on durable writes must stop admission rather than fall back to memory.

Worker journals are private append-only recovery records containing command IDs,
acknowledgments, generations, provider IDs, event cursors, and artifact references.
They cannot authorize new work or overwrite Agamemnon's task decisions. Do not add
a separate SQLite task/control store.

### APIs, manifests, and messages

Extend Agamemnon under `/v1/fleet` with pool, worker, session, execution, and
build-job resources. Publish REST/OpenAPI and client contracts for create/start,
inspect, input, interrupt, cancel, resume, drain, acknowledgment, and event-cursor
operations. Document which operations apply to each resource and reject invalid
transitions. Mutations require idempotency keys and applicable generation checks;
reusing a key with different content fails explicitly.

Add `ExecutionPool` under the existing `myrmidons/v1` API, Codex program support,
and optional pool references. Model backend (`native`, `container`, `slurm`) and
purpose (`agents`, `builds`) separately. Include host, worker count, conversations
per worker, allocation/overhead budgets, runtime version, image reference,
authentication-profile references, admission, and schedule. Execution domain and
HMAS role are distinct from the existing administrative role. Domain/role values
remain extensible; a fixed research hierarchy is not a runtime dependency.

Preserve existing APIs and manifests. Version incompatible wire extensions.
Use versioned Fleet envelopes, initially `schema: hi/fleet/v1`, with correlation,
idempotency, command/event IDs, generation, and target identity. Preserve canonical
work subjects `hi.myrmidon.{domain}.{role}.task.{taskId}` and existing acknowledgment
semantics. Specify additional Fleet control/event subjects and access rules without
creating a second task queue. Cursor ordering is defined per stream/source;
duplicates and gaps require explicit handling, not an assumed global clock order.

Legacy epic-registration subscriptions use Core NATS. The Fleet path requires
tested durable delivery, replay, and parent-task wakeups; subscribing to a subject
alone does not establish JetStream durability. Producer acknowledgment and
consumer processing checkpoints are separate requirements.

## 4. Runtime, resource, and transport design

### Five Codex runtimes

Use worker-owned Codex 0.153.4 app-server communication for interactive and
automated Fleet execution. Preserve existing non-Fleet `exec` integration. Generate
or validate protocol bindings against the pinned executable and test lifecycle,
approval requests, input, interruption, cancellation, and restart/resume behavior.

Each runtime independently establishes native authentication to the existing
ChatGPT account and has one private authentication owner/storage directory.
Do not copy a shared refresh-token bundle across workers or turn each logical
conversation into an authentication owner. Disable nested subagents initially.
Verify account concurrency, refresh behavior, provider usage, and rate limits
before scaling; the 108 target is an acceptance requirement, not an assumption
that the account already supports it.

Admission requires a tested tool execution boundary. Native macOS and a generic
Linux platform check do not establish isolation. The pinned app-server supports
named execution environments, but registration alone neither isolates files and
processes nor gives a logical agent exclusive ownership. Defaults can select
every registered environment. Fleet must fence environment identity by logical
agent and generation, disable local/default fallback, and select exactly one
owned environment on each supported start/turn operation. Resume needs explicit
binding reconciliation because its wire schema has no environment field.

Validate an isolated tool environment per logical session while retaining the
five provider runtimes and their private authentication. The candidate uses
contained `codex exec-server` processes with only the admitted workspace exposed.
Test actual model-tool routing, sibling/private-state access, detached children,
and confirmed disposal before opening admission. A successful no-auth direct
process probe alone cannot establish the model's ordinary tool path. Unsupported
backends must report unavailable rather than fall back to local tools.

### Initial resource profiles

M1 and M2 identify Linux Slurm clusters, not Apple processor models.

| Target | Runtime count × conversations | Allocation per runtime/job | Reserved supervision | Usable workload budget |
|---|---:|---|---|---|
| Laptop | 1 × 12 | Compare native macOS with an 8-vCPU / 12-GiB Linux VM | Measure runtime and host headroom | Validate locally |
| M1 agent pool | 2 × 24 | 72 CPUs / 288 GiB; zero GPUs | 8 CPUs / 32 GiB | 64 CPUs / 256 GiB per runtime |
| M2 agent pool | 2 × 24 | 72 CPUs / 288 GiB; zero GPUs | 8 CPUs / 32 GiB | 64 CPUs / 256 GiB per runtime |
| M1 laptop-tool pool | Separate build capacity | 18 CPUs / 72 GiB; zero GPUs | 2 CPUs / 8 GiB | 16 CPUs / 64 GiB |
| M2 laptop-tool pool | Separate build capacity | 18 CPUs / 72 GiB; zero GPUs | 2 CPUs / 8 GiB | 16 CPUs / 64 GiB |

Native and VM laptop runs are comparison alternatives; only one contributes 12
agents to combined acceptance. The 96 cluster agent slots remain available when
laptop tools are offloaded. On M1, use admitted CPU capacity on large nodes with
zero GPU requests; do not assume its small `cpuonly` partition fits these budgets.

Treat these budgets as initial measurements to validate. Slurm/container cgroups
enforce aggregate runtime resources and explicit build-job limits. Conversations
inside one app-server process do not have separate CPU/memory cgroups. Role-based
capacity estimates are admission budgets, not a claim of per-conversation isolation.
Tool environments may have separate enforced process boundaries inside an
allocation. These do not create additional provider runtimes or admitted agent
slots. Measure their overhead within the existing budgets; prove the chosen
Slurm/Pyxis backend supports their isolation and cleanup. Do not use `--overlap`
to bypass resource accounting.

Check requested resources against scheduler admission, allocation TRES, and actual
cgroup limits. Refuse inconsistent ledgers. Queue the 13th laptop, 49th agent on
either cluster, and 109th global agent when the corresponding capacity is full.
Never silently shrink resource requests or count queued work as active.

### Slurm/Pyxis and authenticated attachment

Use Slurm/Pyxis for cluster workers and build jobs. Pin images by actual digest and
record job ID, node, runtime identity, and execution generation. Login-node commands
are transient submission/inspection/attachment operations; no permanent login-node
service is required.

An allocation-local Keystone gateway carries existing work, acknowledgment, replay,
and event semantics over authenticated attachment. Prove an actual reachable path
from the laptop through permitted SSH/Teleport and allocation commands. A login-node
loopback forward does not inherently reach a compute-node loopback endpoint. Prefer
a framed stdio attachment where supported; document any required endpoint and its
authentication. Do not expose a public worker listener.

The gateway must preserve durable consumer identity, explicit acknowledgment,
progress renewal, redelivery, and unacknowledged messages on disconnect. Transport
failure cannot acknowledge unfinished work. Provider connectivity from compute
nodes is also a measured prerequisite.

Add an ADR for externally managed Slurm clusters, the native-laptop comparison,
and SSH/Teleport as an HPC-specific extension to the architecture's Tailscale
topology. Preserve accepted scheduler decisions and the existing mesh transport
in their current environments.

### Ordinary SSH hosts

Support a persistent non-root container worker on conventional SSH hosts using
the same logical-agent, workspace, journal, and control contracts. Before
registration, discover OS/architecture, compatible Podman or Docker runtime,
enforceable resource limits, Git, writable persistent storage, image compatibility,
and authenticated attachment/reconnect support. Require tmux only for a transport
mode that actually uses it. Report missing mandatory capabilities as `UNSUPPORTED`;
never silently fall back to host-native execution.

A trusted host bootstrap owns container-engine operations and restart policy.
Worker containers do not receive an engine socket to launch sibling containers.
Validate this backend with a separate SSH canary; it does not replace any laptop,
M1, or M2 capacity in the required demonstration.

## 5. Credentials, workspaces, and image evidence

Run a laptop-only OpenBao service for Fleet-managed identities and scoped
infrastructure secrets. Only the trusted `fleetd` adapter accesses OpenBao. Agents
and workers never receive its token. Use pool-scoped attachment identities where
required; distribute short-lived Fleet credentials through private scoped storage,
using ephemeral mounts where compatible with their lifecycle.

Apply a maximum five-day lifetime to Fleet-issued credentials that Fleet can
actually expire or revoke, and bound admission authority accordingly. Display
actual issuer expiry, renewal state, and warnings at 24 hours and one hour when
known. Teleport certificate expiry and native Codex authentication follow their
actual issuers. Display unavailable provider expiry as unknown. OpenBao KV storage
does not by itself expire or revoke a stored credential; its TTL is advisory.
See the [OpenBao KV API documentation](https://openbao.org/docs/2.4.x/api/secret/kv/kv-v1/).

Native Codex refresh credentials remain in each runtime's private authentication
storage, outside Fleet per-conversation secret distribution. Unusable required
credentials block new admission. Preserve resumable state and request renewal
without silently substituting broader credentials. A Fleet admission lease expiring
is distinct from a provider token being revoked.

| Work class | Workspace policy | Credential policy |
|---|---|---|
| Planning, research, review | Read-only source snapshot plus separate writable output | No Git write credential; export results through an authorized artifact/publication path |
| Contributor | Isolated per-task writable worktree | Scoped repository/branch/PR operations, subject to repository review rules |
| Long-running specialist | Dedicated persistent clone and workload state | Only workload-scoped credentials |

Record repository URL, immutable base SHA, branch, workspace path/ID, ownership,
and cleanup status. Use explicit, tested permission profiles to prevent cross-agent
workspace and credential access; setting a conversation's working directory alone
does not prove isolation. Show both assigned policy and verified enforcement in
Odysseus badges. Protected-branch restrictions require credential/server-side
enforcement; an isolated worktree alone cannot enforce them.

The initial no-auth Codex 0.153.4 process probe found that the native macOS
`:minimal` policy still permits shared temporary-directory access. The worker now
rejects native macOS session admission. Continue the laptop comparison with an
isolated Linux VM/container and measure its actual enforcement before admitting
work; do not count a configured profile as successful native isolation. Keep
provider authentication, controller state, and private input spools outside shared
scratch and outside agent workspaces. Give tools a private environment and exclude
the worker's `.fleet-runtime` scratch directory from source snapshots and delivery.

Use non-root images, private writable homes, read-only image layers where supported,
and explicit mounts. Never expose the controller's home/environment, SSH agent
socket, Teleport credentials, OpenBao token, or container-engine socket to agents.
Do not put secrets in source snapshots, images, terminal logs, journals, or artifacts.
Enroot's operational isolation is not a hostile-code sandbox; work requiring stronger
isolation must be routed to a backend that supplies it.

AchaeanFleet and Proteus produce pinned Linux amd64/arm64 images and build-generated
SBOMs/provenance bound to the observed image digest, source revision, dependencies,
and toolchain. Keep unresolved image references unset with admission disabled until
a real build and validation supply evidence. A handwritten digest or SBOM is not
build evidence.

## 6. Heavy laptop tools

Provide Fleet MCP build submission, status/log-cursor, and cancellation operations.
Route laptop Hephaestus build/test stages through the same service. A submission
identifies `workspaceId`, registered `recipeId`, validated parameters, and an
idempotency key. Build jobs are Agamemnon-admitted work executed through Keystone;
the MCP server is not another queue owner.

Recipes use registered `just` or `pixi run` commands with declared resources,
timeouts, toolchain/image requirements, and artifact policy. Transfer an immutable
source snapshot including relevant uncommitted changes and eligible untracked files,
while excluding credentials and Git administration data. Preserve required file
modes and define symlink/submodule handling so the remote build sees the intended
source without importing unrelated host files.

Generate receipts independently of the requesting agent, binding snapshot, recipe,
toolchain, allocation, outcome, and artifact digests. Verify them on collection.
If the local source changes after submission, mark the result stale. Linux results
do not establish macOS-specific behavior. Build workers do not need ChatGPT
credentials, and heavy jobs consume the separate tool allocations above.

## 7. Lifecycle and recovery

Specify legal pool transitions from stopped/scheduled through submission, queue,
bootstrap, ready, draining, terminating, and stopped. Expose unsupported, error,
and lost/reconciliation-required conditions. Specify session transitions through
requested, queued, assigned, preparing, starting, running, waiting for input or
approval, completing, and confirmed terminal outcomes. Preserve uncertain outcomes
instead of reporting success or cancellation from missing heartbeats.

Combine durable claims, generation fencing, worker inventory, and Keystone replay.
Heartbeat expiry alone cannot authorize a replacement while prior execution may
still be running. Prove termination or establish an effective fence before retrying.
Task idempotency is necessary where applicable but does not make concurrent writers
safe. Preserve unfinished workspaces for recovery.

Keep these operations distinct:

- **Detach:** close an attachment; retain admitted execution and journaled output.
- **Interrupt:** request the active turn to stop and retain resumable conversation state.
- **Drain:** stop new admission and let admitted work finish within policy/deadline.
- **Cancel:** terminate the specified execution and record the confirmed outcome.
- **Resume:** reconcile the existing claim, workspace, runtime, and generation before continuing.

A disconnected or sleeping laptop permits remote completion of already-admitted
work only. Remote workers accept no additional issues. Local agents resume after
wake and reconciliation. Persist worker results until delivery is acknowledged;
replay must not release dependent work twice. Slurm requeue, worker/app-server
death, authentication expiry, and event gaps require explicit reconciliation.

After acceptance, enable the weekday schedule in `America/Los_Angeles`:

1. **08:00:** submit allocations after current authentication and admission checks.
2. **17:00:** drain; place no new work in the pools.
3. **18:00:** enforce an explicit allocation termination deadline. Preserve receipts
   and resumable state, interrupt remaining work, and confirm scheduler termination.
   Report unfinished outcomes honestly.

Release an empty allocation early. Freeing a logical slot does not return part of
a fixed Slurm allocation. Outside the schedule, automatic allocation acquisition
is disabled; a manual start requires current authentication and admission. A
force-stop action shows concrete affected executions, requires explicit operator
confirmation, and records an audit event. Test daylight-saving transitions,
missed startup while asleep, restart, and deadline enforcement without relying
solely on a connected laptop.

## 8. Observability and acceptance evidence

Argus provides aggregate metrics for ready/active capacity, queue latency, heartbeat
age, allocation state, startup failures, credential expiry where known, drain
duration, transport health, resource use, and offload latency. Keep session IDs
and other unbounded identifiers in access-controlled logs and audit records,
outside metric labels.

Alert through Odysseus on lost workers/allocations, failed scheduled starts,
inconsistent capacity, required credential expiry, durable-write failures, event
gaps, and draining past the termination deadline. Correlate work issues, commands,
generations, allocations, receipts, and experiment IDs without exposing secrets.

Scylla records the experiment inputs and measures completed, independently approved
work; active occupancy; elapsed time; CPU/memory use; provider usage when available;
rate-limit delays; retries; offload latency; and operator intervention. Record
unavailable measurements as unavailable. Charybdis injects faults through Agamemnon's
supported chaos interfaces. Only outputs from actual runs support performance or
recovery claims, under [ADR-014](adr/014-runnable-evidence-for-metric-claims.md).

## 9. Implementation sequence and release gates

Work in each component's own isolated repository and PR process. Deliver compatible
contracts before dependent integrations. Odysseus owns the web application,
cross-component documentation, and integration harness. Preserve review/publication
rules, accepted ADRs, and canonical configuration coordination; update submodule
pins only after explicit integration sign-off.

| Phase | Deliverables | Required evidence before promotion |
|---|---|---|
| 1. Architecture and persistence | Proposed ADRs; ownership/storage boundaries; API/manifests; durable claims and command intent; restart hydration; Projects projection | GitHub failure injection rejects dispatch; no memory-only Fleet; duplicate/concurrent claims fenced; restart reproduces state; Project mapping and repair work |
| 2. Runtime and transport canaries | Pinned Hephaestus app-server adapter; AchaeanFleet images/SBOMs; allocation-local Keystone gateway; LaunchAgent; SSH discovery | Real protocol/approval lifecycle; independent native authentication and refresh; actual compute attachment and provider connectivity; Slurm resource enforcement; ordinary SSH reconnect canary |
| 3. Integrated vertical slices | Odysseus research/interview flow, planned-issue flow, interactive session; durable epic/role delivery; UI approvals and evidence | All three paths use canonical ownership; durable claims, acknowledgments, replay, epic registration, and parent wakeups; no alternate task queue |
| 3a. Live ownership and flow | Per-item/component/agent activity views; system topology and live message traces | Actual task-to-agent-to-host linkage; observed publish/delivery/ack traces; reconnect and cursor-gap recovery; visible stale/unknown states; bounded telemetry and no payload leakage; measured browser update latency |
| 4. Offload and recovery | Registered recipes/MCP and Hephaestus integration; immutable snapshots and receipts; OpenBao policies; drain/cancel/reconcile controls | Snapshot fidelity and stale-result handling; permission/credential isolation; worker/app-server death, disconnect, Slurm requeue, auth expiry, duplicate/out-of-order delivery, and confirmed cancellation via Charybdis |
| 5. Performance ramp | Scylla experiments and Argus dashboards; native-versus-VM comparison; prepared real issue cohorts | Cluster ramps at 1, 2, 4, 8, 16, 24, 48 per cluster; laptop at 1, 2, 4, 8, 12; admission overflow tests; measured provider/scheduler/durability limits |
| 6. Combined acceptance | All five runtimes concurrently execute the reviewed issue cohort | 12 laptop + 48 M1 + 48 M2 genuinely active on real admitted work; implementation, independent review, and build/test represented; correlated occupancy and outcome evidence |
| 7. Scheduled operation | Enable weekday submission/drain/deadline and operational runbooks | 08:00/17:00/18:00 behavior, current-auth manual start, no automatic after-hours restart, no duplicate allocations, hard termination despite laptop disconnect |

Prepare **108 reviewed, independent eligible issues plus replacements** before the
combined run. Check dependencies, existing PRs, likely file overlap, toolchains,
review readiness, and writer claims. Existing backlog volume alone is insufficient.
Unknown overlap cannot silently permit concurrent writers. Account or scheduler
limits that prevent 108 are blockers to report and resolve, not permission to lower
the target or count idle conversations.

Use unit/contract tests for state transitions, persistence failures, idempotency,
generation fencing, schema compatibility, cursor gaps, and policy enforcement.
Use real service/container/cluster canaries for transport, authentication, cgroups,
snapshot receipts, and recovery claims. A mocked integration test does not satisfy
an infrastructure acceptance gate. Publish reproducible `just`/`pixi run` commands
and retain independently generated artifacts for review.

## 10. Reconciliation with the attached draft

The reattached laptop-controlled draft is identical to the original investigation
input. This plan restores its compatible operational requirements while preserving
the later user decisions:

| Draft requirement | Consolidated decision |
|---|---|
| Laptop web console and service | Unified Odysseus web application; LaunchAgent-managed `fleetd` as Agamemnon's adapter |
| Ordinary SSH workers and terminal backscroll | Capability-gated container backend and diagnostic attachment; separate SSH canary |
| OpenBao and five-day credentials | Fleet-secret management with enforceable issuer lifetimes; native Codex authentication stays private per runtime |
| Workspace badges, image SBOMs, alerts | Restore with verified enforcement, actual build evidence, and aggregate metrics |
| Four providers shipping together | Codex first; preserve later-provider extension points |
| One fully consumed 128-CPU / 512-GiB pool | Five runtimes serving 108 agents; corrected per-runtime overhead and separate tool capacity |
| Per-conversation tmux/container/Slurm step | Five shared provider runtimes with independent logical ownership; tested tool execution boundaries and aggregate allocation limits |
| Separate local control database; metadata-only NATS | GitHub-backed orchestration, private recovery journals, Keystone canonical work/control/event transport |
| Separate `SlurmPool` API namespace | Compatible `myrmidons/v1` `ExecutionPool` with explicit backend and purpose |
| Indefinite drain after 17:00 | Preserve admitted work until completion or the explicit 18:00 allocation deadline |
| Implicit compute loopback reachability | Prove authenticated allocation attachment before depending on it |
| Deferred Telemachy integration | Complete the Nestor → Telemachy → Agamemnon path in the integrated vertical slices |

No Fleet workloads, cluster performance runs, or combined acceptance results are
claimed by this plan. Implementation work already started in isolated component
worktrees remains subject to these gates.

Local validation now includes actual pinned-provider configuration/process probes,
real private JetStream/gateway transport, and a composite attachment/worker test
using explicitly synthetic authority and provider fixtures. A local dashboard
fixture also exercises 108 item records and browser update timing. None of these
substitutes for positive GitHub-backed admission, authenticated model work, isolated
Linux enforcement, or concurrent real issue acceptance.

The next execution gates now use actual image builds and no-auth process probes.
Preserve complete pinned runtime payloads, including bundled sandbox resources;
image startup and package checks are separate from sandbox enforcement. Initial
local runs use small bounded containers and do not substitute for the required
8-vCPU/12-GiB laptop VM comparison or the full cluster profiles.

Research intake also requires a durable admission adapter: Nestor's existing
in-memory acceptance and unchecked publish results do not establish dispatched
Fleet work. Telemachy's producer must obtain a durable publish acknowledgment and
reconcile uncertain GitHub issue creation without recreating epics or children.
Consumer replay and parent wakeups cannot compensate for an unconfirmed producer.

Implement the research bootstrap under Nestor's explicit Fleet intake interface.
Use an operator-configured GitHub state repository and branch for deterministic
intake metadata paths. A SHA-conditional transition reserves one creation
attempt; competing writers and uncertain outcomes cannot issue another create.
Store only identities, request digests, phase and confirmed issue references in
that metadata. Publishable requirements stay in the work issue; private interview
content stays private. This addition is a Proposed architecture extension with
live GitHub write/concurrency and restart tests still required.

The real Telemachy producer and native Agamemnon consumer have passed a local
exact-byte integration test through a private JetStream broker. Lost publisher
receipt, failed durable write, duplicate delivery, restart and canonical child
completion/parent wakeup are covered with a controlled GitHub fixture. Retain
this evidence separately from production admission and complete workflow tests.

The initial Fleet registration adapter uses an explicitly marked, pre-existing
epic issue to hold registration phases and frozen workflow identity. Uncertain
child creation is reconciled across open and closed issues; absence cannot
authorize another create after a lost response. An exclusive registration writer
is a required deployment condition. Automatic first-epic creation and enforced
writer handoff remain intake/recovery work, and must be completed for the full
research-to-implementation acceptance flow.

Private command/file approval and question forms now use authenticated backend
reads from a configured same-host worker socket. Each read binds current
controller ownership and the provider turn; file acceptance also binds the
displayed change evidence. Responses pass through a private spool reference and
Agamemnon's durable `respond` command. Missing file evidence disables acceptance.
Remote private attachment, conversation history and end-to-end authenticated
model work remain implementation gates.

Every implementation or CI repair PR must pass its repository's local CI/CD,
hosted checks and the Athena PR review before merge. Repair broken checks in a
repo-specific subtask, then rerun them against the final reviewed head. Keep
component architecture and interface documentation current with each change.
Review findings, disabled runtime tests, failed packaging and baseline CI failures
must be resolved before claiming that the affected PR is ready. Preserve
submodule integration approval and the separate runtime acceptance gates.
