# Research intake from the web application

The Research intake view submits publishable requirements to Nestor's explicit
Fleet intake API. Nestor owns the GitHub-backed intake record and work issue.
Odysseus authenticates the local user and proxies the supported HTTP operations;
it does not create issues itself, keep an intake queue, or dispatch research
agents. A confirmed issue is the endpoint's result, not completed research.

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
confirmed issue. It removes that retained request before enabling a new form.
Clearing browser data manually loses this recovery record; record the intake ID
and reconcile with Nestor before submitting the same work under another ID.
The retention scope is one browser profile and origin; it is not a global work
claim or an alternative durable authority.

## Verification

Run `just web-test`, `just web-build`, and `just web-browser-test`. Backend
fixtures exercise authentication, exact payloads, Unicode/digest compatibility,
invalid input, uncertain outcomes, bounded concurrency and rejected receipts.
Browser fixtures exercise unchanged retries across reload, status-only lookup,
storage failure, altered retained bytes and competing tabs through the actual
backend proxy with a controlled Nestor HTTP transport.

These checks do not prove live GitHub CAS ownership, research worker dispatch,
interviews, epic registration, or the full research-to-implementation flow.
