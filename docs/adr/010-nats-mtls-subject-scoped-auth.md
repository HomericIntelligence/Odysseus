# ADR 010: NATS Mutual-TLS Authentication and Subject-Scoped Authorization

**Status:** Proposed

> **Proposal status:** The identity and authorization contract below becomes
> binding only if this ADR is accepted and implemented. The checked-in NATS
> configuration and verified live-state readbacks remain the authorities for
> current behavior.

---

## Context

When this ADR was proposed, the checked-in `server.conf` and `leaf.conf`
already configured TLS on the NATS listeners, which protected message payloads
in transit when those files were deployed with valid certificates. Proposed
ADR-008 documented the intended TLS requirement but was not the source of that
runtime state. The hub configuration already used shared-token bootstrap
authentication on its client, leafnode, and cluster listeners, and the
outbound leaf remote supplied the leaf token. The leaf node's local client
listener remained unauthenticated. TLS still omitted peer verification and
identity mapping, and the configuration had no named accounts or
subject-scoped permissions. The proposal addressed these risks in that earlier
checked-in state:

- A holder of the shared client token could publish or subscribe across the
  full `hi.*` subject space, including agent commands and research results.
- Any process able to reach a leaf node's local client listener could connect
  without authentication.
- A holder of the shared cluster token could join the NATS cluster without a
  distinct peer identity.
- Leaf nodes used a shared token and did not present client certificates, so
  the hub could not bind a connection to a unique leaf identity.

Tailscale provides host-level isolation but is not a substitute for
application-layer authentication. A single compromised host could otherwise
expose the full mesh. Issue #175 identified that proposal-time condition as
CRITICAL.

The current checked-in `configs/nats/server.conf` and `configs/nats/leaf.conf`
now include certificate verification, named accounts, subject permissions, and
listener or route authentication. Those files define repository configuration;
they do not prove the configuration deployed on any host. This ADR remains
Proposed and does not itself establish current live state.

Only commented operator, NKey, and JWT migration examples existed in that
snapshot; there was no active operator/NKey/JWT configuration. The checked-in
configuration and repository history established the TLS certificate/key and
CA bundle path convention under `/etc/nats/certs/`; Proposed ADR-008 records
related design context. This ADR proposes extending that foundation to enforce
identity and least-privilege authorization using NATS's built-in
`verify_and_map` mechanism. AID v0.2.0 (Ed25519 + scoped JWT) is the documented
future path and is deferred to a subsequent ADR.

## Decision

### 1. Mutual TLS on every listener

- **Client listener (port 4222):** `verify_and_map = true` — clients must present a CA-signed
  certificate; the cert's SAN-DNS value is mapped to an account user identity.
- **Leafnode listener (port 7422):** `verify = true` — leaf nodes must present a CA-signed cert.
- **Cluster listener (port 6222):** `verify = true` — cluster peers must present a CA-signed cert.
- **Leaf remote (outbound):** leaf nodes present a client cert+key when connecting to the hub, so
  the hub can authenticate the leaf.

### 2. Proposed cert identity convention for `verify_and_map`

If this ADR is accepted, every client and leaf node certificate **MUST** carry:

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
| `AGENTS` | `agent.homeric` | `hi.agents.>`, `hi.tasks.>` | `hi.agents.>`, `_INBOX.>` |
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
- If implemented, the proposal would address #175 by rejecting anonymous
  client connections fail-closed.
- Cluster peers and leaf remotes would authenticate with CA-signed identities.
- Least-privilege subject scoping would prevent an AGENT identity from
  subscribing to all tasks and a KEYSTONE identity from publishing arbitrary
  `hi.*` subjects.
- The proposed SAN-DNS convention would be an issuance-time, testable contract.

**Negative:**
- Every client and leaf would need a valid role certificate before enforcement
  could be enabled. Plain connections would be rejected once
  `verify_and_map` became active.
- Before implementation, the current Hermes, Telemachy, Compose, and other
  NATS clients would require a fresh exact-pin capability and configuration
  inventory. Proposal-time client paths and defaults are not deployment facts.
- Cert provisioning and distribution adds operational overhead. See
  `docs/runbooks/enable-nats-auth.md` for the step-by-step procedure.

**Neutral:**
- The HTTP monitoring endpoint (`127.0.0.1:8222`) is unchanged; it remains plain HTTP on loopback.
- Cert issuance would stay out-of-band (Keystone / Myrmidons), consistent with ADR-008.
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
