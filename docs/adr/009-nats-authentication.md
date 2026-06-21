# ADR 009: Require Authentication for All NATS Connections

**Status:** Proposed

---

## Context

ADR-008 added TLS to every NATS link, but TLS only encrypts the channel and
proves possession of the shared mesh CA — it does not establish *which* leaf
node connects. `leaf.conf` connected its `remotes` stanza with no credentials
and `server.conf` declared no `authorization`/`accounts`, so any host copying
the canonical config could relay into the mesh anonymously (issue #176).

## Decision

1. The `server.conf` client listener, the `leafnodes {}` listener, AND the
   `cluster {}` route listener each declare their own `authorization {}`.
   Anonymous connections are rejected (fail-closed). A client-only
   authorization is insufficient — the leafnode and cluster listeners each
   stay open without their own block. Cluster peers share JetStream and
   subjects, so an unauthenticated route is broader than a leaf relay
   (issue #318, follow-up to #176). Note: the `cluster {}` listener does not
   support the `token` field; bootstrap credentials use `user`/`password`
   (`$NATS_CLUSTER_USER`/`$NATS_CLUSTER_PASSWORD`) instead.
2. `leaf.conf` `remotes` supplies a credential. Preferred:
   `credentials = "/etc/nats/certs/leaf.creds"` (per-leaf NKey/JWT,
   revocable). Bootstrap fallback: embed `$NATS_LEAF_USER`/`$NATS_LEAF_PASSWORD`
   in the remote URL (`nats+tls://$NATS_LEAF_USER:$NATS_LEAF_PASSWORD@<ip>:7422`).
   Note: the `remotes` stanza does not support a bare `token` field; credentials
   must be in the URL or a `.creds` file. The `leafnodes {}` server-side
   `authorization {}` likewise uses `user`/`password`, not `token`.
3. Credentials are never committed. Static tokens use env substitution
   (mirroring `$NATS_MONITORING_PASSWORD`); `.creds` files live under
   `/etc/nats/certs/` (chmod 600) and are git-ignored.
4. `tools/validate-nats-auth.sh` (run by `just validate-configs` locally AND
   a dedicated `ci.yml` step on `pull_request`) rejects any credential-less
   canonical config — including a `cluster {}` listener without authorization
   (issue #318). CI also runs `nats-server -t` with dummy TLS certs and all
   required credentials to confirm the authed configs parse correctly.

## Consequences

**Positive:**

- Any leaf node that copies the canonical config without provisioning a
  credential is rejected at connect time — fail-closed by default.
- Per-leaf NKey/JWT `.creds` (recommended path) gives individual leaf
  revocation without rotating a shared secret.
- The validator gate prevents future drift: any PR that removes auth from the
  canonical configs fails CI.

**Negative:**

- Operators must provision credentials (`$NATS_LEAF_USER`/`$NATS_LEAF_PASSWORD`
  or `leaf.creds`, plus `$NATS_CLUSTER_USER`/`$NATS_CLUSTER_PASSWORD`) before
  first connect. See `docs/runbooks/add-new-host.md` step 5.
- The static `$NATS_LEAF_USER`/`$NATS_LEAF_PASSWORD` bootstrap provides no
  per-leaf revocation. Production deployments should migrate to per-leaf `.creds`.

**Neutral:**

- The `$NATS_CLIENT_TOKEN` env var follows the same pattern as the existing
  `$NATS_MONITORING_PASSWORD` substitution already in `server.conf`.
- Decentralized NKey/JWT auth (operator + account JWTs) is the long-term
  recommended posture; the `user`/`password` bootstrap blocks are explicitly
  documented as a placeholder for the upgrade path.
- `nats-server` v2.10.x does not support `token` inside `leafnodes {}` or
  `cluster {}` authorization blocks; only the top-level client `authorization {}`
  accepts `token`. All listener-specific blocks use `user`/`password`.

## References

- [ADR 002](002-nats-event-bridge.md) — NATS event bridge decision
- [ADR 008](008-nats-tls-encryption.md) — TLS encryption layer this ADR extends with
  identity authentication
- [Issue #176](https://github.com/HomericIntelligence/Odysseus/issues/176)
  — NATS leaf-node config has no authentication (part of #174)
