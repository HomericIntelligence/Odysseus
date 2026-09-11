# Odysseus Fleet web application

The Fleet web application presents work ownership, the GitHub pipeline projection,
and observed message flow from Agamemnon and Keystone. It is an initial implementation of the
[Fleet plan](../docs/homeric-fleet-plan.md); research intake, conversation history,
terminal attachment, workflow views, retained Argus dashboards,
and experiment execution remain implementation work.

## Run locally

1. Install Node.js 22.12 or newer and `just`.
2. From the Odysseus repository, run `just web-install`.
3. Run `just web-test` and `just web-build`.
4. Run `just web-start`. The service binds to `127.0.0.1:8765` and prints the
   location of its private local access-token file. Open that address and use the
   file's token to sign in. The token is distinct from provider authentication.
5. Configure the supported sources below and restart the backend to connect
   actual component records and observations. Without sources the application
   deliberately shows an empty view.

| Variable | Purpose |
|---|---|
| `ODYSSEUS_WEB_PORT` | Loopback port; default `8765` |
| `ODYSSEUS_WEB_STATE_DIR` | Private local state; default `~/.local/state/odysseus-web` |
| `ODYSSEUS_WEB_TOKEN` | Optional operator-supplied UI token; otherwise generated in private state |
| `ODYSSEUS_AGAMEMNON_URL` | Supported controller endpoint; HTTPS except for loopback HTTP |
| `AGAMEMNON_API_KEY` | Backend credential for the controller |
| `ODYSSEUS_NATS_URL` | Optional TLS observation endpoint |
| `ODYSSEUS_NATS_CREDS_FILE` | Private NATS credentials file for the observation subscription |
| `ODYSSEUS_NATS_CA_FILE` | Optional private CA bundle for the TLS connection |
| `ODYSSEUS_NATS_ALLOW_LOCAL` | `1` permits a plaintext literal-loopback broker for local testing |
| `ODYSSEUS_ENABLE_COMMANDS` | `1` explicitly enables supported session commands |
| `ODYSSEUS_INPUT_SPOOLS` | JSON mapping of worker IDs to private absolute spool directories |
| `ODYSSEUS_WORKER_STATE_DIRS` | JSON mapping of worker IDs to private same-host directories containing `worker.sock`, for approvals/questions |

Keep secrets in private backend configuration; never commit them or embed them
in a URL. HTTP cookies are HttpOnly and SameSite Strict, with a 30-minute session
limit. The server rejects foreign origins and Host headers. Remote browser access
requires a separately reviewed TLS/authentication deployment; do not expose this
loopback service through an unauthenticated proxy.

## Ownership and flow

The backend polls all five `/v1/fleet` resource collections. It accepts a coherent
snapshot only when every collection is complete and each identity is valid and
unique. A failed poll retains the previous records with an unavailable-source
indicator. The UI links the canonical session, logical agent, role, worker,
execution, host, pool, allocation, stage, and generation where reported.

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

The browser receives authenticated SSE snapshots once per second. Cursor epochs,
bounded history, rejected/truncated frames, source sequence gaps, and disconnects
remain visible. Historical traffic is bounded to 250 observations by default;
older data is not retained across backend restart. Loss counters describe observed
coverage limits, not an estimate of all missing network packets. Host and item
correlation require an unambiguous matching generation and owner.

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

Remote input requires an authenticated private spool-transfer/attachment service;
setting a local path does not implement that transport. Workers absent from the
spool mapping do not expose input controls. Full provider conversation output
remains implementation work.

## Private agent requests

Workers configured in both `ODYSSEUS_WORKER_STATE_DIRS` and
`ODYSSEUS_INPUT_SPOOLS` expose approval and question controls. Both directories
must be canonical, private and outside the agent workspace. The worker socket
must be user-owned with no group or other access. A local path cannot reach a
remote cluster worker; an authenticated private attachment service is required
before remote requests can be enabled.

The authenticated `/api/requests` read accepts one session, worker and generation.
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

Drafts and uncertain submissions remain in page memory through sign-in renewal;
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
presentation, missing evidence, explicit retry and sign-in renewal. These tests
do not establish remote attachment or authenticated provider acceptance.

The independent local integration canary has exercised actual Keystone gateway
observations and the JavaScript writer/Python private-input reader. Positive
controller/provider integration used explicitly synthetic authority and provider
fixtures. No real GitHub admission, model turn, cluster allocation, or 108-agent
performance result follows from those tests.
