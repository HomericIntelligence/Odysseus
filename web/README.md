# Odysseus Fleet web application

The Fleet web application presents work ownership, the GitHub pipeline projection,
and observed message flow from Agamemnon and Keystone. It is an initial implementation of the
[Fleet plan](../docs/homeric-fleet-plan.md). A Research intake view now submits
publishable requirements through Nestor's supported durable intake API. A selected session
can display an explicitly registered, retained command-output bundle. Conversation history,
terminal attachment, workflow views, retained Argus dashboards,
and experiment execution remain implementation work.

## Run locally

1. Install Node.js 22.12 or newer and `just`.
2. From the Odysseus repository, run `just web-install`.
3. Run `just web-test` and `just web-build`.
4. Run `just web-start`. The service binds to `127.0.0.1:8765`. Open that address
   to see the dashboard directly; no local access token or sign-in is required.
5. Configure the supported sources below and restart the backend to connect
   actual component records and observations. Without sources the application
   deliberately shows an empty view.

| Variable | Purpose |
|---|---|
| `ODYSSEUS_WEB_PORT` | Loopback port; default `8765` |
| `ODYSSEUS_OBSERVATION_HISTORY_DIR` | Optional canonical owner-only directory outside source and shared scratch for the bounded observation restart cache |
| `ODYSSEUS_AGAMEMNON_URL` | Supported controller endpoint; HTTPS except for loopback HTTP |
| `AGAMEMNON_API_KEY` | Backend credential for the controller |
| `ODYSSEUS_NATS_URL` | Optional TLS observation endpoint |
| `ODYSSEUS_NATS_CREDS_FILE` | Private NATS credentials file for the observation subscription |
| `ODYSSEUS_NATS_CA_FILE` | Optional private CA bundle for the TLS connection |
| `ODYSSEUS_NATS_ALLOW_LOCAL` | `1` permits a plaintext literal-loopback broker for local testing |
| `ODYSSEUS_ENABLE_RESEARCH_INTAKE` | `1` enables the Nestor intake proxy using backend credentials |
| `ODYSSEUS_NESTOR_URL` | Nestor HTTP endpoint; HTTPS except for loopback HTTP |
| `NESTOR_AUTH_TOKEN` | Backend-only bearer credential for Nestor |
| `ODYSSEUS_ENABLE_RESEARCH_IMPORT` | `1` enables confirmed-intake import and known-task reads using the configured Agamemnon endpoint and credential |
| `ODYSSEUS_ENABLE_COMMANDS` | `1` explicitly enables supported session commands |
| `ODYSSEUS_EXECUTION_HOST` | Controller host identity for this machine; defaults to the operating-system hostname |
| `ODYSSEUS_INPUT_SPOOLS` | JSON mapping of worker IDs to private absolute spool directories |
| `ODYSSEUS_WORKER_STATE_DIRS` | JSON mapping of worker IDs to private same-host directories containing `worker.sock`, for approvals/questions |
| `ODYSSEUS_SESSION_OUTPUT_BUNDLES` | JSON array of operator-collected immutable output bundles; each entry supplies `path`, `receiptDigest` and full `identity` |

Local-machine access is the UI trust boundary. The server requires loopback
access, allows only its local Host values, and rejects foreign origins and
cross-site requests. Writes require a matching `Origin` header. There is no UI
token, session cookie, login endpoint, or session expiry. `ODYSSEUS_WEB_TOKEN`
and `ODYSSEUS_WEB_STATE_DIR` are unused; existing access-token files are left
untouched and are no longer read.

Keep component and provider credentials in private backend/runtime configuration;
never commit them or embed them in a URL. Keyless local access does not enable
commands, bypass Agamemnon admission, or provide a private worker attachment.
Remote browser access requires a separately reviewed TLS/authentication deployment;
do not expose this loopback service through an unauthenticated proxy.

The dashboard stays visible while connecting or reconnecting. Missing and stale
observations remain explicit, and stale ownership disables commands. Recovery
resumes read-only observations; it never automatically replays a write.

## Ownership and flow

The backend polls all five `/v1/fleet` resource collections. It accepts a coherent
snapshot only when every collection is complete and each identity is valid and
unique. A failed poll retains the previous records with an unavailable-source
indicator. The UI links the canonical session, logical agent, role, worker,
execution, host, pool, allocation, stage, and generation where reported.

Subordinate build rows show their tool worker and allocation. Item details keep
the retained parent task, agent, worker and generation in a separate group.
Controller status and update time describe durable lifecycle changes; an
`authorized` build still has unknown observed activity. Tool host placement is
not reported by this protocol. No provider-worker lookup fills it in, and parent
identity does not create a child agent. Raw paths, policy bodies and grants never
enter the browser projection. Malformed typed ownership remains unavailable.
An invalid typed build ID is replaced by a stable opaque display key and the
label "Build identity unavailable". The key cannot name a controller resource
or be used as command scope; neither the raw ID nor its snapshot path is shown.

Controller reads expire after 15 seconds even if the browser's snapshot stream
continues. Retained ownership and activity are marked explicitly in item details;
stale records cannot enable commands. Selecting an owner reveals and focuses the
detail panel on narrow screens, and closing it restores focus to the selection.

Assignment and activity are separate. The active issue-agent counter requires a
canonical `claimed` session, issue/task identity, and recent observed model/tool
activity. Build jobs, reserved claims, idle sessions, duplicate agent identities,
and stale observations do not count. This display is not the independently
approved-work metric required by the 108-agent acceptance experiment.

The flow map shows application-message observations, not network packet capture.
Inactive edges describe intended topology. Moving markers require actual
observations; each trace identifies its source, operation, result, time,
correlation, and measured byte count where supplied. Publish, delivery, and ACK
are separate observations, so their count is not an end-to-end message rate.
An ACK observation does not imply issue completion. Payloads, prompts, terminal
bytes, and credentials are excluded from the telemetry schema.

Use either or both observation inputs:

1. Subscribe through the backend to `hi.fleet.observations.>` using NATS credentials
   scoped to observation access. This is a Core telemetry subscription, not a
   durable work consumer. Production observation publication/Argus retention
   must be configured separately.
2. Start the backend with `just --command npm --prefix web start -- --flow-stdin`
   and feed newline-delimited gateway `type: observation` frames through a
   trusted private pipe. Agamemnon's `fleetd --observations-fd` provides this
   output. Give each writer its own pipe and frame-aware fan-in; do not let
   several writers interleave partial JSON on one FIFO. The dashboard never
   consumes or acknowledges task delivery for visualization.

The browser receives local SSE snapshots once per second. Cursor epochs,
bounded history, rejected/truncated frames, source sequence gaps, and disconnects
remain visible. Historical traffic is bounded to 250 observations by default.
Without the optional restart cache, history is memory-only. Loss counters describe observed
coverage limits, not an estimate of all missing network packets. Host and item
correlation require an unambiguous matching generation and owner.

## Recorded command output

Select a session, then choose **Load command logs**. This read works independently
of session command enablement. It shows collected command records, provider exit
codes and combined stdout/stderr as plain text. Logs load only on request and
remain in the selected panel's memory. Closing the panel removes them. They never
enter browser storage, dashboard snapshots, SSE or shared message telemetry.

The first profile consumes `hi/fleet/session-output/v1` from Hephaestus. It retains
only observed completed command items from Codex 0.153.4. It always reports
`complete: false`: the provider does not prove complete output or distinguish an
empty aggregate from unavailable output when it returns null. Collector truncation
and omitted item counts remain visible. Provider completion and exit code are not
independent test approval, task completion or a successful Fleet run.

To attach output from a completed worker capture:

1. After canonical completion or cancellation, deliver the retained facts,
   confirm execution disposal, and stop the worker normally. Use Hephaestus's
   bounded `hephaestus-fleet-worker export-output` operation on its retained
   private state. It requires the worker's journal writer lock to be free.
   Preserve the actual export receipt and immutable file. This operation reads
   evidence; it does not start a provider or issue new work.
2. For a VM worker, collect those exact bytes through the approved VM connection.
   Verify the received file's SHA-256 against the export receipt. This web feature
   does not supply remote collection or streaming.
3. Place the file in an owner-only directory outside shared scratch, this checkout
   and all canonical local agent workspaces. The file must be owner-only, regular,
   canonical, and have one hard link. Keep this private root excluded from future
   worker workspace mounts.
4. Add its absolute `path`, exact-byte `receiptDigest`, and full expected `identity`
   to `ODYSSEUS_SESSION_OUTPUT_BUNDLES`. Identity contains `workerId`, `generation`,
   `allocationId`, `sessionId`, `executionId`, `taskId`, `agentId` and
   `providerThreadId`. Use actual receipt values; the browser cannot supply a path.
   Configure the backend Agamemnon endpoint, credential and local execution host.
5. Restart the backend normally and load logs from the matching session. A new
   collected snapshot requires a new explicit registration and restart; loaded
   bundles are immutable. No directory scanner or automatic attachment exists.

The reader verifies the whole-file digest, scope, closed schema and item digests.
It accepts at most 64 items, 64 KiB of retained output per item, 1 MiB of encoded
item records and 2 MiB per bundle. It checks complete workspace inventories before
private reads, including cached reads. An unresolved typed build disables access.
It then checks the canonical session owner: changed, released, terminal or deleted
ownership is labelled historical. Unavailable ownership or invalid evidence is an
explicit error, never an empty log or a claim that no commands ran.

Live ownership and activity continue through the normal component observations.
Recorded command output is a separate collected snapshot, not a live terminal.

## Observation history across restart

The **Observation history** view shows original observation and receive times,
sequence numbers, identities, and live or restored origin. Restored observations
do not create active workers, work controls, moving packets, component activity
lights, or current traffic counts. The cache contains sanitized metadata only;
private output, prompts, credentials, raw frames, resource inventories, and source
health are excluded. Argus remains the owner of long-term metrics and logs.

1. Create a dedicated directory owned by the dashboard user, with mode `0700`,
   outside all source checkouts and shared scratch. Use its canonical absolute
   path. Do not share the directory between hosts or containers.
2. Set `ODYSSEUS_OBSERVATION_HISTORY_DIR` to that path and restart the backend.
   The exclusive loopback listener must succeed before cache writes or input
   attachment. Each port uses `observations-<port>.json` and one temporary
   sibling, `observations-<port>.json.tmp`. A second backend on the same port
   cannot write the cache.
3. Check Observation history and `/api/snapshot`'s `history` metadata. A missing
   file is a new archive; a restored file preserves original times and sequence
   order. The view distinguishes memory-only, new or empty archive, restored
   history, partial retention, pending persistence, and unavailable history.
   A confirmed `persistedSequence`/`persistedAt` covers the saved prefix only.
   Displayed pending observations are not yet confirmed durable.
4. Check the status after actual source events arrive. Do not inject example
   traffic into an operator dashboard. Persistence is serial: one write and
   one replaceable pending snapshot, with at most one second of coalescing.
   Each write syncs an owner-only temporary file, atomically replaces the cache,
   then syncs the directory. Only completion advances the confirmation receipt.
5. Graceful shutdown is installed before observation intake, including while
   NATS setup is pending. On shutdown, intake stops and HTTP returns `503` while
   the writer attempts a final flush for at most five seconds. The backend holds
   its exclusive listener until that flush completes or reaches its deadline.
   A late NATS connection closes without attaching an observation subscription.
   A timeout remains uncertain even if an earlier filesystem operation finishes
   later. No later write phase or confirmation starts after the deadline.
   Every restart reports a discontinuity and creates a new SSE epoch. An old
   browser cursor reports a gap; no cache proves what happened during downtime.
6. If persistence is unavailable, preserve the files and inspect the reported
   reason. Invalid, oversized, unsupported, linked, non-regular, wrong-permission,
   or unreadable files are not overwritten. A leftover temporary member requires
   operator recovery; a valid committed cache is restored read-only. The backend
   does not adopt/delete the temporary member or probe its former writer's PID.
   Stop the backend before operator recovery. Preserve the affected directory
   for inspection and configure a new empty private directory if recovery cannot
   establish a safe committed file.
7. To return to memory-only operation, remove the optional setting and restart.
   Existing cache and temporary files remain untouched.

Schema `hi/odysseus/observation-history/v1` has a closed object shape and validates
both reads and writes. It retains at most 250 observations, 1,000 derived
deduplication identities, and 1,000 source-sequence entries. Each file is capped
at 4 MiB; reads stop at that cap plus one byte. There are at most two capped
members. Byte/count retention loss remains explicit. Arbitrary JSON bytes are
never truncated, and unrelated directory entries are never scanned or pruned.

A failure before replacement preserves the prior committed bytes. If replacement
succeeds but directory sync fails, complete new bytes can be visible with uncertain
durability. The backend preserves them and keeps the prior confirmation receipt.
It does not claim rollback of a completed rename. Live in-memory observations
remain visible after a storage failure. This local cache cannot recover already
lost events, record preparation as execution, or make Core NATS delivery complete.

## GitHub pipeline

The Pipeline view independently polls Agamemnon's supported
`GET /v1/fleet/projects` endpoint every 30 seconds. It shows canonical
orchestration state, separately reported Hephaestus stage labels, work issues,
orchestration records, and actual linked PRs. Agent ownership comes from matching
Fleet session claims. Multiple reported owners remain visible for inspection.

The backend validates the versioned issue-backed projection and its complete,
bounded collection before replacing the previous view. Unsupported responses,
timeouts, and malformed rows preserve the last projection with an unavailable
source indicator. Projects failure does not invalidate the Fleet resource view.
The UI does not reconcile the board, change labels, or authorize issue work.

Health-read freshness is separate from the controller's last rebuild attempt and
last successful rebuild timestamps. A recent read cannot make an old or degraded
rebuild successful. Reads older than 90 seconds are stale. Missing initial
counters remain unmeasured; changed board items are not completed or approved
work. A disabled or absent projection does not establish an empty backlog.

Configure the existing ProjectV2 and explicit field/option mapping in Agamemnon
using its `AGAMEMNON_PROJECTS_CONFIG` contract. The web backend uses its existing
Agamemnon credential. No Project, permission, or configuration is created here.

## Research intake

Choose **Research intake** to submit publishable requirements to Nestor. The
browser retains an immutable request before the first submission and preserves
it across reloads for explicit retries. Status inspection is read-only. A link
appears only after Nestor confirms the matching issue; uncertain responses keep
the request locked. Other tabs adopt the retained request instead of creating a
new identity. Storage failure prevents submission.

With the separate import flag enabled, **Import research task** submits only the
confirmed intake ID and digest to Agamemnon. The browser persists that reference
and expected issue before POST, under the same lock as intake retry and replacement.
Unknown outcomes block a new selection; reload and reconnect never automatically
POST. Explicit retries preserve the reference and later replay state.

Task refresh uses only the known canonical task ID. The backend validates intrinsic
L3/provenance identity and the exact raw claim/owner, then rereads the task to detect
transitions. The UI compares the result with its selected receipt. Unavailable reads
retain historical evidence without offering a guessed owner link. Assignment is
distinct from activity, and imported tasks add no active agents.

Actual import/read HTTP observations enter the existing bounded flow stream with
correlation IDs and measured bytes where available. They do not invent worker
generations or internal delivery/ACK events. These endpoints record an issue and
its Pending task; they do not dispatch research agents or complete research. See
the [intake API and recovery guide](../docs/research-intake-api.md) for routes,
configuration, limits, ownership checks and recovery.

## Session commands and private input

Commands are disabled by default. With the explicit enable flag and configured
controller, select an existing Fleet session to start, input, interrupt, cancel,
or resume when its state permits. Agamemnon performs resource admission and
durable task claiming. These controls do not create tasks or establish another
orchestration authority. Worker drain is not a session operation.

Before each submission the backend fetches the current controller record and
checks session, worker, and generation. It then calls the supported session
operation with a stable command ID and idempotency key. A submitted receipt
means controller acceptance, not execution or cancellation completion. Lost
responses and conflicts retain the exact request for an explicit same-ID retry.
The UI never automatically replaces uncertain work.

For input, configure a private local directory shared with that worker's trusted
`fleetd` attachment. It must be canonical, user-owned, mode `0700`, outside shared
temporary storage, and outside all agent workspaces. The backend writes the
scoped `hi/fleet/private-input/v1` object as an exclusive mode `0600` file, flushes
the file and directory, and sends only its opaque reference through Agamemnon.
An unchanged retry reuses the file; a different body under the same identity is
rejected. Failed or uncertain submissions retain files for reconciliation.
Automatic spool retirement is not implemented; retire inputs only after the
owning adapter confirms consumption and retention requirements are satisfied.

Before private access, the backend fetches complete controller session, execution
and build-job inventories and checks every configured private root against all
local workspaces, including other workers and retained records. Missing host or
workspace identities, incomplete inventories and unresolved local paths block
access. Configure `ODYSSEUS_EXECUTION_HOST` if the controller uses a different
logical name for this machine. A session on another host cannot use local private
paths. Configure the same private-root exclusions in Hephaestus so future workspace
mounts cannot overlap them; a web inventory check does not authorize admission.

If a typed subordinate build is present, the current controller protocol cannot
supply its absolute protected placement. Private input, responses and request
reads remain unavailable, including after a terminal build is retained. The UI
shows "Build workspace placement is unresolved" from a fixed backend reason;
private files and socket readers are not accessed. A failed retry retains the
original command identity and any earlier uncertain outcome. Do not work around
this gate by adding generic host/workspace fields or removing retained records.
The separate inventory dependency and its acceptance criteria are in
`docs/homeric-fleet-plan.md`, under "Heavy laptop tools".

Remote input requires an authenticated private spool-transfer/attachment service;
setting a local path does not implement that transport. Workers absent from the
spool mapping do not expose input controls. Full provider conversation output
remains implementation work.

## Private agent requests

Workers configured in both `ODYSSEUS_WORKER_STATE_DIRS` and
`ODYSSEUS_INPUT_SPOOLS` expose approval and question controls. Both directories
must be canonical, private and outside every local workspace. The worker socket
must be user-owned with no group or other access. A local path cannot reach a
remote cluster worker; an authenticated private attachment service is required
before remote requests can be enabled.

The local `/api/requests` read accepts one session, worker and generation.
It fetches the current controller record and checks private worker inventory
before and after reading the pending provider requests. Missing ownership,
changed turns, disconnects or unavailable evidence disable fresh decisions.
Command approval shows the actual command. File approval shows only changes from
the matching private worker evidence response; no evidence means no acceptance.
The response fingerprint binds both the provider request and displayed changes.
Question forms retain exact provider question IDs and keep secret answers masked.

Answers use the same durable controller path as session commands: the backend
rechecks the request, writes a scoped private response file, then sends only the
reference and request ID through Agamemnon's session `respond` operation. A
decision for changed evidence is rejected. The raw response, command, diff and
questions are excluded from Fleet snapshots and telemetry.

Drafts and uncertain submissions remain in page memory through a disconnect;
they are not written to browser storage. An explicit retry reuses the command ID
and exact response. If the provider request has disappeared, only matching
durable command intent and the retained private file can confirm prior controller
acceptance. This is not provider completion. Reloading the page clears its private
drafts; worker/controller records remain available for reconciliation.

## Verification

Run `just web-browser-install` once to install Playwright Chromium and its
platform dependencies, then `just web-ci` for formatting, unit tests, build and
browser tests. These same gates run in the required hosted web job and the
repository's `pixi run --locked ci` recipe. An existing Chromium executable can
be selected with `PLAYWRIGHT_CHROMIUM_EXECUTABLE`. Individual recipes remain
`just web-test`, `just web-build`, `just web-format-check` and
`just web-browser-test`.
Browser tests create loopback fixture servers and intercept command requests;
they do not dispatch real issue work. Tests must build current assets first.

The private-request tests use actual local Unix sockets with synthetic worker
inventory. They cover owner/turn changes, evidence-bound file decisions, typed
request IDs and exact question answers. Browser tests cover private request
presentation, missing evidence, explicit retry and reconnect. These tests
do not establish remote attachment or authenticated provider acceptance.

The independent local integration canary has exercised actual Keystone gateway
observations and the JavaScript writer/Python private-input reader. Positive
controller/provider integration used explicitly synthetic authority and provider
fixtures. No real GitHub admission, model turn, cluster allocation, or 108-agent
performance result follows from those tests.
