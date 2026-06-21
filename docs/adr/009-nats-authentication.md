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

1. The `server.conf` client listener AND the `leafnodes {}` listener each
   declare their own `authorization {}`. Anonymous connections are rejected
   (fail-closed). A client-only authorization is insufficient — the leafnode
   listener stays open without its own block.
2. The `cluster {}` route listener on `0.0.0.0:6222` also requires
   `authorization { token = "$NATS_CLUSTER_TOKEN" }` (issue #306). TLS alone
   only verifies the mesh CA — any host holding the CA cert could otherwise
   join as a full cluster peer (broader than a leaf relay: route peers share
   JetStream state and the full subject space). The cluster token must match
   on every peer in a multi-server cluster. Single-host deployments with no
   configured routes are unaffected at runtime; the block is inert unless
   routes are added, but is required for config correctness going forward.
3. `leaf.conf` `remotes` supplies a credential. Preferred:
   `credentials = "/etc/nats/certs/leaf.creds"` (per-leaf NKey/JWT,
   revocable). Bootstrap fallback: `token = "$NATS_LEAF_TOKEN"` via NATS env
   substitution.
4. Credentials are never committed. Static tokens use env substitution
   (mirroring `$NATS_MONITORING_PASSWORD`); `.creds` files live under
   `/etc/nats/certs/` (chmod 600) and are git-ignored.
5. `tools/validate-nats-auth.sh` (run by `just validate-configs` locally AND
   a dedicated `ci.yml` step on `pull_request`) rejects any credential-less
   canonical config. The validator tracks brace depth to extract each
   listener block independently — a `cluster{}` block with TLS but no
   `authorization{}` inside it fails even if an `authorization{}` exists at
   a different nesting level. CI also runs `nats-server -t` to confirm the
   authed config parses and that an unset token resolves to empty
   (fail-closed), not a literal.

## Consequences

**Positive:**

- Any leaf node that copies the canonical config without provisioning a
  credential is rejected at connect time — fail-closed by default.
- Per-leaf NKey/JWT `.creds` (recommended path) gives individual leaf
  revocation without rotating a shared secret.
- The validator gate prevents future drift: any PR that removes auth from the
  canonical configs fails CI.

**Negative:**

- Operators must provision a credential (`$NATS_LEAF_TOKEN` or
  `leaf.creds`) before first connect. See `docs/runbooks/add-new-host.md`
  step 5.
- Multi-server cluster deployments must also set `$NATS_CLUSTER_TOKEN` (the
  same value on every peer) before starting any server that participates in a
  cluster. See `docs/deployment.md` §4a.
- The static `$NATS_LEAF_TOKEN` bootstrap provides no per-leaf revocation.
  Production deployments should migrate to per-leaf `.creds`.

**Neutral:**

- The `$NATS_CLIENT_TOKEN` env var follows the same pattern as the existing
  `$NATS_MONITORING_PASSWORD` substitution already in `server.conf`.
- Decentralized NKey/JWT auth (operator + account JWTs) is the long-term
  recommended posture; the token blocks are explicitly documented as a
  bootstrap placeholder.

## References

- [ADR 002](002-nats-event-bridge.md) — NATS event bridge decision
- [ADR 008](008-nats-tls-encryption.md) — TLS encryption layer this ADR extends with
  identity authentication
- [Issue #176](https://github.com/HomericIntelligence/Odysseus/issues/176)
  — NATS leaf-node config has no authentication (part of #174)
- [Issue #306](https://github.com/HomericIntelligence/Odysseus/issues/306)
  — NATS cluster route listener has TLS but no authorization
