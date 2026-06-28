# ADR 010: NATS Mutual-TLS Authentication and Subject-Scoped Authorization

**Status:** Proposed

---

## Context

ADR-008 added TLS encryption to all NATS listeners (`server.conf` and `leaf.conf`), protecting
message payloads in transit. However, both configs omit `verify` / `verify_and_map` on every TLS
block, and neither config includes an `accounts {}` or `authorization {}` block. As a result:

- Any process that can reach port 4222 over Tailscale can connect and pub/sub all `hi.*` subjects,
  including agent commands and research results.
- Any peer that can reach port 6222 can join the NATS cluster (`0.0.0.0:6222`, no auth).
- Leaf nodes present no client certificate to the hub; any TLS connection from port 7422 is
  accepted.

Tailscale provides host-level isolation but is not a substitute for application-layer authentication
— a single compromised host exposes the full mesh. Issue #175 identifies this as CRITICAL.

No operator, NKey, or JWT scaffolding exists in the repository. ADR-008 already established a
mutual-cert PKI under `/etc/nats/certs/` with `ca.pem` as the trust anchor. This ADR extends that
PKI to enforce identity and least-privilege authorization using NATS's built-in `verify_and_map`
mechanism. AID v0.2.0 (Ed25519 + scoped JWT) is the documented future path and is deferred to a
subsequent ADR.

## Decision

### 1. Mutual TLS on every listener

- **Client listener (port 4222):** `verify_and_map = true` — clients must present a CA-signed
  certificate; the cert's SAN-DNS value is mapped to an account user identity.
- **Leafnode listener (port 7422):** `verify = true` — leaf nodes must present a CA-signed cert.
- **Cluster listener (port 6222):** `verify = true` — cluster peers must present a CA-signed cert.
- **Leaf remote (outbound):** leaf nodes present a client cert+key when connecting to the hub, so
  the hub can authenticate the leaf.

### 2. Cert identity convention (binding contract for `verify_and_map`)

Every client and leaf node certificate **MUST** carry:

1. A Common Name of the form `CN=<role>.homeric`
2. A DNS Subject Alternative Name equal to `<role>.homeric`

NATS `verify_and_map` matches identities in the following precedence order:
SAN email → **SAN DNS** → RFC-2253 Subject DN.
The `accounts {}` `user` field is therefore set to the **SAN-DNS string** (e.g. `hermes.homeric`),
not a bare CN substring. A bare CN is never a match key.

Defined roles and their SAN-DNS values:

| Role | SAN-DNS | Purpose |
|------|---------|---------|
| `sys.homeric` | `sys.homeric` | NATS system account |
| `hermes.homeric` | `hermes.homeric` | Event bridge; creates JetStream streams |
| `agent.homeric` | `agent.homeric` | Myrmidon worker agents |
| `keystone.homeric` | `keystone.homeric` | DAG consumer (homeric-tasks) |
| `telemachy.homeric` | `telemachy.homeric` | Workflow runner |

**Issuing a role cert (using `step` CLI):**

```bash
# Example: hermes identity cert with required DNS SAN
step ca certificate hermes.homeric hermes-cert.pem hermes-key.pem \
  --san hermes.homeric
```

The `--san` flag sets the DNS SAN that `verify_and_map` matches. The CN is set automatically to
`hermes.homeric` when the first positional argument equals the SAN value.

**Fallback (discouraged):** If a SAN cannot be added, the `accounts {}` `user` field may instead
be set to the full RFC-2253 Subject DN (e.g. `CN=hermes.homeric,O=HomericIntelligence`). DN-order
fragility makes this error-prone; the SAN-DNS convention is strongly preferred.

### 3. Subject-scoped `accounts {}`

Five accounts are defined, each scoped to the `hi.*` subtree relevant to its role (ADR-005):

| Account | User (SAN-DNS) | Publish | Subscribe |
|---------|----------------|---------|-----------|
| `SYS` | `sys.homeric` | — | — |
| `HERMES` | `hermes.homeric` | `hi.>`, `$JS.API.>` | `hi.>`, `_INBOX.>` |
| `AGENTS` | `agent.homeric` | `hi.agents.>`, `hi.tasks.>` | `hi.agents.>`, `_INBOX.>` (deny `hi.research.>`) |
| `KEYSTONE` | `keystone.homeric` | `$JS.API.CONSUMER.>`, `$JS.API.STREAM.INFO.>`, `$JS.ACK.>` | `hi.tasks.>`, `_INBOX.>` |
| `TELEMACHY` | `telemachy.homeric` | `hi.tasks.>`, `$JS.API.>` | `hi.tasks.>`, `_INBOX.>` |

`system_account = SYS` designates the NATS internal system account.

### 4. Future path: AID v0.2.0 (NKey + scoped JWT)

Decentralized identity using Ed25519 operator/account/user NKeys and NATS JWT is the intended
long-term auth mechanism (referenced in the ecosystem audit as AID v0.2.0). It supersedes
cert-mapped accounts when an operator key and resolver are provisioned. That transition is deferred
to a subsequent ADR and tracked in the HomericIntelligence roadmap.

## Consequences

**Positive:**
- Closes #175: anonymous connections to port 4222 are rejected fail-closed.
- Cluster port 6222 now requires a CA-signed peer cert; arbitrary peers cannot join.
- Leaf remotes authenticate to the hub; unauthenticated leaf connections are rejected.
- Least-privilege subject scoping: AGENTS cannot read `hi.research.>`; KEYSTONE cannot publish
  arbitrary `hi.*` subjects.
- `AuthorizationError` is already classified as non-retryable in the Hermes publish retry loop, so
  auth failures surface immediately rather than burning retry budget.
- The SAN-DNS convention is a hard, testable contract: `step ca certificate` enforces it at
  issuance time.

**Negative:**
- Every client and leaf must present a valid role cert before enforcement is enabled. Enforcement is
  fail-closed: plain `nats://` connections are rejected once `verify_and_map` is active.
- Three downstream clients default to plain `nats://` today and must be reconfigured before NATS
  is restarted with the new config:
  - `ProjectHermes` (`infrastructure/ProjectHermes/src/hermes/config.py:34`) — already mTLS-capable
    via `TLS_CERT_FILE`/`TLS_KEY_FILE`/`TLS_CA_BUNDLE` env vars; needs configuration only.
  - `ProjectTelemachy` (`provisioning/ProjectTelemachy/src/telemachy/config.py:21`) — has a
    `require_tls` gate but no client-cert wiring; tracked in follow-up issue
    "ProjectTelemachy: add NATS client-cert (mTLS) wiring".
  - `docker-compose.crosshost.yml:45` — `NATS_URL: nats://nats:4222`; must be updated and a client
    cert mounted before enforcement is enabled.
- Cert provisioning and distribution adds operational overhead. See
  `docs/runbooks/enable-nats-auth.md` for the step-by-step procedure.

**Neutral:**
- The HTTP monitoring endpoint (`127.0.0.1:8222`) is unchanged; it remains plain HTTP on loopback.
- Cert issuance stays out-of-band (ProjectKeystone / Myrmidons), consistent with ADR-008.
- Cert rotation (NATS `nats-server --signal reload`) is standard TLS operational overhead,
  unchanged from ADR-008.

## References

- [ADR 008](008-nats-tls-encryption.md) — TLS encryption for all NATS listeners (this ADR
  extends its PKI)
- [ADR 009](009-nats-authentication.md) — Token-based authentication on every NATS listener
  (issue #176). This ADR strengthens that baseline: cert-mapped subject-scoped accounts replace
  the client token, while the leafnode and cluster listeners retain their `authorization {}`
  blocks for fail-closed bootstrap.
- [ADR 005](005-nats-subject-schema.md) — `hi.*` subject schema that the account permissions
  mirror
- [ADR 002](002-nats-event-bridge.md) — Decision to use NATS JetStream as the event bridge
- [Issue #175](https://github.com/HomericIntelligence/Odysseus/issues/175) — CRITICAL: NATS
  server has no TLS and no authentication
- [Issue #174](https://github.com/HomericIntelligence/Odysseus/issues/174) — Parent audit issue
- [NATS `verify_and_map` documentation](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro/tls_mutual_auth)
- [NATS accounts configuration](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/accounts)
- [Smallstep `step` CLI](https://smallstep.com/docs/step-cli/) — Recommended cert issuance tool
