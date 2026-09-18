# Research intake and canonical task status

The Research intake view submits publishable requirements to Nestor's explicit
Fleet intake API. Nestor owns the GitHub-backed intake record and work issue.
Odysseus authenticates the local user and proxies the supported HTTP operations;
it does not create issues itself, keep an intake queue, or dispatch research
agents. A confirmed issue is the intake endpoint's result, not completed research.
An independently configured import action submits that confirmed reference to
Agamemnon, which owns its durable task identity and execution admission.

## Operator setup

1. Deploy Nestor with its explicit Fleet intake adapter configured. Follow
   [Nestor's Fleet intake contract](https://github.com/HomericIntelligence/Nestor/blob/main/docs/fleet-intake.md):
   the state repository and branch must already exist, and required bearer
   authentication must be enabled. The legacy in-memory `/v1/research` endpoint
   is not used by this view.
2. Set `ODYSSEUS_ENABLE_RESEARCH_INTAKE=1` and `ODYSSEUS_NESTOR_URL` in private
   backend configuration. HTTPS is required except for loopback HTTP.
3. Supply `NESTOR_AUTH_TOKEN` privately to the Odysseus backend. Do not embed it
   in a URL or provide it to the browser. The browser uses the existing local
   Odysseus sign-in session.
4. Run `just web-install`, `just web-build`, then `just web-start`. Open the
   loopback interface, sign in, and choose **Research intake**. The capability
   indicator confirms configuration only; a request establishes actual Nestor
   availability.
5. Enter a work repository, title and publishable requirements. These fields
   become GitHub issue content. Credentials and private interviews must use
   their separate private interfaces.

No deployment, credentials, or live GitHub writes are performed by the fixture
checks for this feature. Fleet research admission and dispatch remain gated.

## HTTP contract

All web API operations require the existing local session cookie. Writes also
require a matching `Origin` header. The backend allows at most four in-flight
intake operations, uses a five-second upstream deadline, prohibits redirects,
and bounds request and response bodies. Raw upstream errors are not returned or
logged. The backend does not automatically retry a failed operation.

| Web operation | Supported Nestor operation |
| --- | --- |
| `POST /api/research/intakes` | `POST /v1/research/intakes` |
| `GET /api/research/intakes/{intakeId}?requestDigest={digest}` | `GET /v1/research/intakes/{intakeId}` |

`GET /api/capabilities` includes `researchIntake.enabled`. It is `false` unless
explicitly configured. No Nestor URL or bearer token is exposed.

POST accepts exactly these five fields, preserving their content on each retry:

```json
{
  "schema": "hi/nestor/intake-request/v1",
  "intakeId": "research-0123456789abcdef0123456789abcdef",
  "workRepository": "HomericIntelligence/Odysseus",
  "title": "Research a durable interface",
  "body": "Publishable requirements"
}
```

IDs follow Nestor's 8–64 character lowercase identifier grammar; the web form
uses `research-` plus a random UUID without hyphens. Titles are nonempty and at
most 256 UTF-8 bytes; bodies are at most 60,000 bytes. The full JSON request is
at most 65,536 bytes. Unpaired Unicode surrogates, unknown fields and reserved
`nestor:fleet-intake:` body markers are rejected before upstream access.

A successful response is `{ "intake": <hi/nestor/intake/v1 record> }`. The
backend validates the record identity, phase, generation, timestamps, exact
fields and digest bindings. Request digests use Nestor's sorted-key compact JSON
with the work repository in lowercase. POST also verifies the issue-body digest,
including Nestor's deterministic marker. Status reads require the retained
request digest and never send the title or body.

`prepared` and `creating` records have no issue link. Only `created` with a
`confirmed_issue` receipt can expose a canonical GitHub issue URL whose
repository and positive issue number match the record. Foreign or malformed
receipts remain unconfirmed.

| Result | Meaning and recovery |
| --- | --- |
| `200`, `prepared` | Durable intent exists; retry the same request to continue |
| `200`, `creating` | Creation is awaiting confirmation; retain identity and content |
| `200`, `created` | Nestor confirmed the issue; open its validated link |
| `409` | Conflict; retain the request and reconcile with the operator |
| `404` on status | No confirmed record was found; absence does not authorize a new identity |
| `503` after upstream access | Outcome unknown; inspect or explicitly retry unchanged |
| `400`, local validation failure | Invalid request; it was not submitted |
| `429`, local capacity limit | This request was not submitted |

Nestor may have accepted a request even when the browser or backend timed out.
Elapsed time alone cannot authorize another issue-creation attempt.

## Browser retention and retry

Before the first POST, the browser writes and reads back the exact request and
its SHA-256 digest in origin-scoped local storage. This is publishable input,
not provider credentials or a private interview. Browser storage must be
available. Web Locks serialize access between tabs; another tab adopts an
existing retained request instead of submitting a different identity.

Once retained, the form fields are locked. Reload, tab changes and renewed
sign-in do not automatically resend it. **Check intake status** performs a
read-only lookup. **Retry same intake** explicitly resends the original identity
and content after verifying the retained digest. A changed or malformed retained
request blocks submission rather than being replaced.

**New research intake** is available only after the current view receives a
confirmed issue and any retained import has a known outcome. It removes only
local selection metadata before enabling a new form; it does not delete a task.
Clearing browser data manually loses this recovery record; record the intake ID
and reconcile with Nestor before submitting the same work under another ID.
The retention scope is one browser profile and origin; it is not a global work
claim or an alternative durable authority.

## Import the confirmed reference

Configure `ODYSSEUS_ENABLE_RESEARCH_IMPORT=1` with the existing backend-only
`ODYSSEUS_AGAMEMNON_URL` and `AGAMEMNON_API_KEY`. The URL requires HTTPS except
for loopback HTTP and cannot contain credentials, a query or a fragment. Enabled
but incomplete or invalid configuration fails before the server accepts traffic.
Without the flag, `GET /api/capabilities` reports `researchImport.enabled: false`.
This flag is separate from the Nestor intake and session-command flags.

| Web operation | Supported Agamemnon operation |
| --- | --- |
| `POST /api/research/imports` | `POST /v1/fleet/research-intakes` |
| `GET /api/research/tasks/{taskId}` | `GET /v1/tasks/{taskId}/state`, then the exact claimed Fleet target when present |

Both routes require local sign-in and return `Cache-Control: no-store`. The POST
also requires a matching Origin. It accepts exactly three fields, at most 4096
UTF-8 bytes:

```json
{
  "schema": "hi/agamemnon/research-import/v1",
  "intakeId": "research-0123456789abcdef0123456789abcdef",
  "requestDigest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
```

The ID follows the same 8–64 character lowercase grammar; the digest is exactly
64 lowercase hexadecimal characters. Title, body, namespace, repository, URL,
credentials and alternate routing are not accepted. The backend calls only its
configured controller origin and fixed path. Import and task reads share four
in-flight slots and one five-second aggregate deadline per operation, including
body consumption and any claim-read sequence. Each response is bounded to 2 MiB
and decoded as strict UTF-8 JSON. Redirects and automatic POST retries are disabled.

Agamemnon revalidates the canonical Nestor record on every import. It returns a
raw `hi/agamemnon/research-import-receipt/v1` document containing `taskId`,
`state`, `provenance`, `issue` and `routing`. A new `201` receipt must be Pending;
a `200` replay can report its later canonical state. Neither response dispatches
a worker. Routing is exactly `research` / `task-agent` / `research`.

The backend validates the complete typed `hi/agamemnon/research-intake/v1`
provenance, including namespace, intake ID, request/body digests, generation 1,
attempt ID, issue and timestamps. The task key is `research-` plus SHA-256 of
compact JSON in lexical key order: `intakeId`, `namespace`, `schema`, with schema
`hi/agamemnon/research-task-key/v1`. The receipt must match the submitted reference
and its own canonical issue. The browser separately compares that issue with its
selected confirmed intake. No digest enters a new-route URL or observation.

| Import result | Meaning and recovery |
| --- | --- |
| `201` | A new durable Pending task was confirmed |
| `200` | The same canonical task was returned; preserve its reported state |
| `400 invalid_request` before transport | Invalid input; not submitted |
| `429 busy` | Local capacity exceeded; not submitted |
| `503 not_configured` | Import is disabled; not submitted |
| `404 intake_not_found` | Controller could not confirm the referenced intake; retain identity |
| `409 import_conflict` | Reconcile the retained reference; do not replace it |
| `503 import_unconfirmed` | Outcome unknown after a request may have left the backend |

Errors contain only finite `error` and `outcome` fields. Raw controller bodies,
exception text and credentials are not returned. An upstream error after a POST
was attempted remains `outcome: unknown`; absence or elapsed time cannot authorize
another identity.

Before **Import research task**, the browser persists and reads back the exact
three-field reference and expected issue under the existing intake Web Lock.
It revalidates the retained intake inside that lock. Storage failure or a changed
selection prevents the POST. A successful response retains its namespace, task ID
and provenance for subsequent comparison. Browser metadata is a recovery record,
not task authority.

Reload, renewed sign-in, duplicate clicks and competing tabs never automatically
import. An explicit retry sends the same reference. An unresolved import blocks
**New research intake** inside the same lock. The existing **Check intake status**
action can recover in-memory Nestor confirmation after reload; import does not
add a mandatory Nestor read or freshness timeout of its own.

## Read the selected task and owner

Task refresh accepts only the known `research-` task ID in its path. Query and body
selection inputs are rejected. It never enumerates tasks, POSTs to poll, or uses
the optional Projects view as task authority.

The backend validates outer and nested task ID/state/layer agreement, the
standalone research L3 shape, typed provenance, canonical repository/issue and
recomputed task key. Its `hi/odysseus/research-task/v1` projection contains bounded
`taskId`, `state`, `layer`, `provenance`, `issue`, `assignment`, `claim`, `owner`
and `resolution`. Description, arbitrary delivery metadata and workspace paths
are omitted. The browser compares this intrinsic identity with its retained
receipt and selected intake before displaying an owner action.

Without a claim, owner is null even if an assignment exists. With a claim, the
backend reads only its exact `/v1/fleet/{targetKind}/{targetId}`. That endpoint
returns a bare resource. Task ID and the full canonical claim schema, target,
worker, agent, generation and raw workspace must match. The backend rereads the
task's relevant identity, state and assignment under the same deadline. This
detects observed transitions; it is not an atomic distributed snapshot.

`404 task_not_found`, `409 task_conflict` and `503 task_unavailable` expose no
current owner. The UI retains the earlier confirmed receipt as historical
evidence and marks current status unavailable. It does not interpret a missing
task as permission to import under a new ID. A partial task read cannot mark
the complete Agamemnon resource collection fresh.

Owner navigation requires an exact current resource and execution generation.
An executions claim needs an exact related-session match; otherwise owner text
has no session link. Assignment, active claim, terminal retained claim and fresh
activity remain distinct. Imported or assigned tasks contribute zero active
agents. A manual resolution retains `verifiedApproval: false`; it is not provider
approval or an independently verified completion claim.

## Observe actual HTTP traffic

The adapter emits one request observation when it attempts an outbound call and
a response observation only after receiving a response. Header status such as
`http-201` does not prove that a valid import receipt followed. A pre-response
failure has no response event or synthetic ACK. Invalid input emits no request.

Events use the existing request/response operations, `transport: http`, a source
epoch, monotonic sequence, distinct event IDs and a shared per-attempt message
ID. Correlation and known task IDs connect the selected detail to actual events.
Request byte counts come from serialized input; unmeasured counts are omitted.
Credentials, digests, content, raw errors and workspaces are excluded.

The current bounded FleetView/SSE stream carries these observations. Import
provenance generation 1 is never copied as execution generation, so these events
cannot create a worker link on their own. The adapter invents no internal
Agamemnon-to-Nestor traffic, Keystone delivery/ACK, activity or completion.

## Verification

Run `just web-test`, `just web-build`, and `just web-browser-test`. Backend
fixtures exercise authentication, exact payloads, Unicode/digest compatibility,
invalid input, uncertain outcomes, bounded concurrency and rejected receipts.
Browser fixtures exercise unchanged retries across reload, status-only lookup,
storage failure, altered retained bytes and competing tabs through the actual
backend proxy with a controlled Nestor HTTP transport.

Import tests use controlled Agamemnon HTTP responses and the actual router,
adapter and FleetView. Run the full Node, build and browser gates with
`just web-ci`; full repository validation remains `just ci`. Browser assets must
be built before a separately selected browser run. An explicit supported Chrome
override qualifies that executable only, not an absent default Playwright browser.

These checks do not prove live GitHub CAS ownership, research worker dispatch,
interviews, epic registration, or the full research-to-implementation flow.
