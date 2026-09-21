# Runbook: Enable NATS Mutual-TLS Authentication and Authorization

The checked-in NATS configuration uses mutual TLS with `verify_and_map` and
subject-scoped accounts. This runbook defines the activation boundary; it does
not assert that the configuration is deployed on any host. Proposed ADRs
008-010 provide design context but are not operational authorization.

Enabling this policy is a production authentication and availability change.
Bind the exact deployment, obtain operator approval for the named hosts and
effects, and preserve a verified rollback artifact before changing live state.

## Stop conditions

Do not activate the checked-in configuration when any of these conditions is
true:

- The active server revision, config hash, service manager, bind addresses,
  firewall policy, credential source, or JetStream storage path is unknown.
- Any active client lacks mutual-TLS client-certificate support or has no
  least-privilege account in the selected server policy.
- A certificate's DNS SAN does not exactly match its configured NATS user.
- The staged server and leaf configurations use different authentication
  schemes for the same connection.
- The selected application-account topology cannot preserve the cross-role
  subjects, streams, and consumers required by Accepted ADR-002 and ADR-005;
  the checked-in four-account topology remains isolated without explicit
  exports/imports.
- The pre-change config, credential version, and state backup cannot be
  restored as one versioned recovery set.
- The change or its verification would require an unapproved remote write.

At the current component pins, the full topology does not clear these gates:

- Agamemnon and Nestor do not expose the complete client-cert configuration
  required by the canonical broker policy.
- Telemachy can require a TLS URL but does not load a client certificate.
- Hermes constructs an SSL context in settings, but its pinned publisher does
  not pass that context to the NATS connection.
- The Odysseus console has no dedicated identity in `server.conf`; do not reuse
  Hermes credentials for it.
- `server.conf` expects a leaf user/password while `leaf.conf` supplies a
  token. Those forms are not interoperable.
- The four application accounts isolate identical subject names and JetStream
  state, so Hermes publications cannot reach agent, Keystone, or Telemachy
  consumers without an accepted and implemented topology resolution. Proposed
  ADR-024 is design context only.

Keep the affected paths unavailable until their owning component and config
changes are approved, implemented, reviewed, and integrated.

## 1. Bind the deployment and active clients

Record the exact Odysseus and component commits, deployed config digest,
server binary or image digest, service-manager unit, listener addresses,
JetStream storage, and secret versions. Query the live server and deployment
inventory for every client and leaf. Do not derive that inventory from this
runbook or from checked-in manifests alone.

For each verified client, map its identity to the current policy:

| Identity | Intended scope in `server.conf` |
|---|---|
| `hermes.homeric` | Publish and subscribe on `hi.>` plus required JetStream APIs |
| `agent.homeric` | Publish agent/task subjects; subscribe to agent subjects and inboxes |
| `keystone.homeric` | Consume task subjects and use its bounded consumer APIs |
| `telemachy.homeric` | Publish/subscribe task subjects plus required JetStream APIs |
| `sys.homeric` | NATS system operations only |

An account entry is not proof that the corresponding client can present its
certificate. Verify client support at the exact deployed component pin.

## 2. Stage credentials without replacing live files

Use the operator-owned CA and secret-distribution system to issue one
least-privilege certificate per approved role. Each client certificate must
contain a DNS SAN exactly equal to its configured user, such as
`hermes.homeric`; a common name alone is insufficient.

Stage the CA, certificate, and private key at new versioned paths on each target
host. Before activation:

1. Verify certificate chain, validity, DNS SAN, and intended role.
2. Verify that the certificate and private key form a matching pair.
3. Restrict the private key to the service account and keep it out of Git,
   logs, shell history, and test artifacts.
4. Confirm the client reads all three staged paths and rejects a missing or
   invalid credential.

Do not overwrite the live cert or key during staging. Follow
[`nats-credential-rotation.md`](nats-credential-rotation.md) for an already
active identity.

## 3. Validate a version-matched candidate

Validate the candidate with the exact NATS binary or immutable image used by
the deployment and with secrets supplied through the deployment's secret
mechanism. Record the non-secret config digest, binary/image digest, command
exit status, and output. Confirm that:

- client, cluster, and leaf listeners bind only to approved interfaces;
- persistent JetStream storage is mounted at the expected path;
- every referenced credential exists with the expected ownership;
- every active client has a compatible identity and subject scope; and
- hub and leaf authentication methods match on both sides.

The checked-in hub/leaf mismatch means the current multi-host pair must fail
this preflight. Do not improvise a token, user, password, or account mapping in
the live environment.

## 4. Prove the policy in an isolated canary

Before live activation, run a controlled canary with disposable storage and
non-production credentials. The verification must propagate a failing command
as a failing result and prove all of the following:

- anonymous and untrusted certificates are rejected;
- every approved role can perform one operation inside its exact scope;
- every role is denied at least one representative operation outside its
  scope;
- JetStream operations required by the selected clients work; and
- leaf traffic crosses the hub only when the same approved authentication
  contract is configured at both ends.

Use dedicated canary subjects within each role's allowed namespace. There is no
single `hi.rotation.check` subject that is valid for every role. Never test a
role by borrowing a more privileged certificate.

## 5. Activate through the deployed service manager

Proceed only after the stop conditions are cleared and the operator approves
the exact candidate and rollback set. Use the deployment-owned service manager
and its documented rolling procedure. Do not start a second ad hoc
`nats-server`, publish unbound host ports, substitute a floating image tag, or
reuse another role's credentials.

For a cluster, change one approved node at a time and verify quorum, routes,
storage, and clients before continuing. Activate leaves only after their
authentication configuration matches the hub. If any required client cannot
reconnect, stop the rollout and enter rollback.

## 6. Verify and record completion

Repeat the canary authorization matrix against the approved live endpoints
using dedicated verification identities and bounded subjects. Also verify the
actual client connections, JetStream streams/consumers, cluster peers, and leaf
routes that belong to the bound topology. Use each component's pinned health
recipe or its configured endpoint rather than a hardcoded port.

Completion requires the exact post-change config and image/binary digests,
successful command exit statuses, client/peer readbacks, and cleanup of any
canary resources. A healthy process without authorization and state evidence
is not completion. Preserve a truthful failure if any receipt is unavailable.

## 7. Roll back as one versioned set

Restore the exact pre-change config, credential paths/versions, and deployment
settings through the same service manager. Restore certificate and key pairs
together; never reconstruct the rollback config from `HEAD~1`, remove
authentication directives by hand, or leave a mixed cert/key pair in place.

After rollback, repeat health, client, peer, stream, and consumer readbacks and
record the actual result. Keep the failed candidate and logs as protected
diagnostic evidence without retaining private keys in the repository.
