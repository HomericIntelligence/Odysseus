# Runbook: NATS Credential Rotation and Compromise Response

This runbook defines the safety and evidence boundary for rotating NATS mutual
TLS credentials. It does not authorize a live change or prove that the
checked-in configuration is deployed. Proposed ADRs 008-010 provide design
context; the exact live config, client capabilities, and operator approval
control an operation.

Use [`enable-nats-auth.md`](enable-nats-auth.md) for first-time activation. At
the current pins, that runbook records unresolved client and hub/leaf
compatibility gaps. Do not rotate or activate a path that has not first cleared
those gates.

## Security facts to preserve

The canonical `server.conf` and `leaf.conf` do not configure CRL or OCSP
checking. With `verify_and_map`, a client identity remains usable until at least
one of these conditions applies:

- its certificate expires;
- its DNS SAN no longer maps to an allowed user; or
- the certificate's issuing CA is no longer trusted.

Issuing a replacement certificate does not revoke the old one. Reloading a
server may update config for new connections, but only a controlled restart or
equivalent verified session termination proves that an already-established
connection was dropped.

Private keys, CA signing material, shared credentials, and secret versions are
never repository evidence. Keep them in the operator-owned secret system.

## Authority and stop conditions

Before any routine rotation, CA change, or incident response:

1. Bind the exact server/client commits, deployed config digest, server binary
   or image digest, service-manager units, listener addresses, JetStream
   storage, client inventory, and credential versions.
2. Identify the exact roles and hosts affected, the expected availability
   impact, and the component-owned restart procedure.
3. Obtain operator approval for the named remote writes and service effects.
4. Preserve a protected, versioned rollback set containing the matching
   pre-change cert and key, config, secret references, and service settings.
5. Define role-specific allowed and denied probes plus state/peer receipts.

Stop if any item is unknown, the rollback pair cannot be restored, the current
client cannot load the staged credential, or hub and leaf authentication forms
do not match. If the operation requires private transport or remote
reachability checks that the current environment cannot perform, record the
limitation and move the verification to an authorized environment; do not
replace it with a static or local-only success claim.

## Part 1: Routine rotation of one identity

Rotate one approved identity at a time. The replacement certificate must keep
the exact DNS SAN mapped by the active NATS policy. A common name alone is not
sufficient.

### 1. Stage a new matching pair

Issue the replacement through the operator-owned CA into a new, non-live,
versioned location. Before distribution, verify:

- chain and validity window;
- the exact DNS SAN and intended role;
- that the certificate and private key have the same public key; and
- restrictive key ownership and permissions.

Distribute both files through the approved secret channel to a staging path on
each target. Do not copy either file over its live pathname yet.

### 2. Preserve the rollback pair before replacement

On each target, copy the current certificate and current private key into one
new protected rollback directory before changing either live file. Record both
digests or serial/key identifiers in the private operation receipt. A cert-only
backup is invalid because it cannot restore a matching identity.

Verify the staged pair again on the destination. If any target differs from the
bound inventory, stop the rotation without modifying it.

### 3. Switch the pair through the component procedure

Use the component's deployment-owned rotation or restart procedure. It must
prevent the client from reconnecting while only one half of the pair has been
replaced. Switch both credential references as one versioned configuration
change, restart or reload only the intended component, and verify that it reads
the staged version.

Do not assume a service-unit name from the role name and do not issue a generic
`systemctl restart "${ROLE}"`. Server and leaf certificates require the bound
NATS service procedure; client certificates require the owning component's
procedure.

### 4. Verify the exact role

There is no single test subject valid for every account. Use a disposable,
operator-approved subject or read-only API inside the exact role's policy:

| Identity | Representative in-scope verification |
|---|---|
| Hermes | A bounded canary publish in an approved `hi.*` namespace plus its configured health recipe |
| Agent | A bounded publish on an allowed agent/task subject and a denied subscription outside its scope |
| Telemachy | A bounded task-subject operation after client-cert support is integrated |
| Keystone | A read-only stream-info or bounded consumer operation allowed by its exact API scope |
| Server/leaf | TLS peer, route/leaf identity, and state readback through the deployed server procedure |

The verification command must propagate failure rather than print `FAIL` and
exit zero. Compare the new certificate identity with the pre-change serial,
confirm the expected connection replaced the old one, and clean up canary
resources.

### 5. Complete or roll back

Completion requires successful role-specific authorization, expected client
and peer state, unchanged unrelated roles, and cleanup evidence. Retain the
rollback set until the operator's defined observation window ends.

If verification fails, stop the component, restore both the certificate and
key from the same rollback directory, restore their paired configuration, and
use the component-owned restart procedure. Repeat all health and state
readbacks. Never restore only the certificate or mix generations.

## Part 2: CA rotation

A CA rotation affects every server, leaf, and client. Treat it as a scheduled,
separately approved change with a complete live identity inventory.

### Dual-trust sequence

Use a dual-trust window only when the exact deployed NATS version has been
tested with the candidate CA bundle and every server can be coordinated:

1. Preserve the old CA, all matching cert/key pairs, configs, secret versions,
   and state receipts as one protected rollback set.
2. Stage and validate a bundle containing old and new trust anchors.
3. Widen trust on every server through the deployment-owned rolling procedure.
4. Prove both old-CA and new-CA canary identities behave only within their
   scopes.
5. Rotate every server, leaf, and client pair using Part 1.
6. Prove no required identity still uses the old CA.
7. Narrow trust to the new CA and terminate old sessions through the approved
   server procedure.
8. Prove an archived old-CA canary is rejected and all new identities and state
   remain healthy.

If every server cannot participate, use an approved maintenance window. Do not
partially narrow trust, overwrite a CA bundle directly on live hosts, or claim
zero downtime without measured receipts.

Rollback before trust is narrowed restores the old-only trust set and every
old matching pair. After narrowing, rollback requires the complete old trust
and credential generation across all affected hosts; a CA file alone is not a
rollback.

## Part 3: Suspected compromise

Treat a suspected private-key or CA exposure as an incident. Preserve logs and
forensic evidence, isolate affected hosts through the incident-response path,
and obtain the incident commander's authorization for containment effects.

### Choose the revocation mechanism

- For one role, removing its mapped identity from the active account policy and
  terminating existing sessions denies every certificate with that SAN. This
  intentionally interrupts legitimate instances of the role too.
- For uncertain scope or CA compromise, rotate the CA and every issued pair.
  Reissuing under a potentially compromised CA does not restore trust.

Canonical config edits and live restarts require their own protected approvals.
Prepare and validate the exact candidate before distribution; do not edit live
files ad hoc or derive a rollback from `HEAD~1`.

Rotate any exposed leaf, cluster, monitoring, account-JWT, or secret-manager
credentials as part of the same incident inventory. The current checked-in
hub user/password and leaf token forms do not match; do not perpetuate both or
invent a conversion during response.

### Prove containment

Use an independently controlled probe to establish that the compromised
credential cannot create a new connection or retain an old session. Then prove
that each clean replacement identity has only its expected permissions and
that peers, streams, consumers, and clients match the incident recovery
inventory. A self-authored `PASS` message or a process health response alone is
not containment evidence.

There is no rollback that knowingly restores a compromised key or CA. If a
containment step disrupts a legitimate service, restore service only with a
separately verified clean identity and the incident commander's approval.

## Completion receipt

For any procedure above, record:

- authorization and exact affected inventory;
- pre/post config and binary/image digests;
- non-secret old/new certificate identifiers;
- command exit statuses and independently captured verification output;
- client, peer, stream, and consumer readbacks;
- rollback-set identifier and retention decision; and
- cleanup or a truthful list of incomplete checks.

## References

- [`enable-nats-auth.md`](enable-nats-auth.md) — first-time activation boundary
- [`configs/nats/server.conf`](../../configs/nats/server.conf) — canonical hub source config
- [`configs/nats/leaf.conf`](../../configs/nats/leaf.conf) — canonical leaf source config
- [ADR-008](../adr/008-nats-tls-encryption.md) — Proposed TLS design context
- [ADR-009](../adr/009-nats-authentication.md) — Proposed authentication design context
- [ADR-010](../adr/010-nats-mtls-subject-scoped-auth.md) — Proposed authorization design context
