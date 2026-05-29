# ADR 008: Require TLS for All NATS Inter-Service Communication

**Status:** Proposed

---

## Context

The HomericIntelligence ecosystem uses NATS JetStream (per ADR 002) as the primary event bridge connecting all agents across multiple hosts. The initial `configs/nats/` configuration files used unencrypted `nats://` URIs for both client connections and leafnode remotes, leaving all inter-service messaging in plaintext on the network.

Compounding this, the leafnode remote URL incorrectly pointed to port 4222 (the client port) rather than port 7422 (the dedicated leafnode port), meaning leafnode connections would fail against any properly-configured NATS cluster.

Although the mesh runs on Tailscale, which encrypts traffic at the network layer, defense-in-depth requires encryption at the application layer as well. A compromised Tailscale node or a misconfiguration that bypasses the Tailscale interface (e.g., direct LAN routing, port-forwarded admin access) would expose all NATS message payloads — including agent lifecycle events, task status, and coordination messages — to any observer.

## Decision

1. **All NATS client connections use TLS.** Both `server.conf` and `leaf.conf` include a top-level `tls {}` block with cert, key, and CA file paths, so clients must use `nats+tls://` or `tls://` to connect.

2. **Leafnode listener uses port 7422 with TLS.** `server.conf` declares a `leafnodes { port = 7422; tls {} }` block. This is the standard NATS leafnode port and was previously missing a TLS block.

3. **Leafnode remote uses `nats+tls://` on port 7422.** `leaf.conf` updates the remote URL from `nats://....:4222` to `nats+tls://...:7422`, fixing both the protocol and the port mismatch (see issue #5).

4. **Cluster routes use TLS.** The `cluster {}` block in `server.conf` adds a `tls {}` block so inter-server routes are encrypted.

5. **HTTP monitoring endpoint remains plain HTTP on localhost.** The `http: "127.0.0.1:8222"` endpoint is intentionally left as plain HTTP. It is bound only to loopback and is scraped by local Prometheus — encrypting the monitoring plane is a separate concern with different threat model.

6. **Certificate path convention:** All TLS blocks reference paths under `/etc/nats/certs/`:
   - `server-cert.pem` — server/node certificate
   - `server-key.pem` — private key (permissions: `chmod 600`)
   - `ca.pem` — CA certificate bundle for peer verification

7. **Provisioning is out-of-band.** The config files document three supported provisioning strategies (see below); actual cert issuance is handled by host provisioning (ProjectKeystone / Myrmidons), not by Odysseus configs.

### Supported Certificate Provisioning Strategies

| Strategy | Tool | Best For |
|----------|------|----------|
| Tailscale TLS certs | `tailscale cert <hostname>` | Hosts already on the Tailscale mesh |
| ACME / Let's Encrypt | `certbot` or `step-ca` with ACME | Public hostnames with DNS challenge |
| Self-signed internal CA | `step ca init` + `step ca certificate` | Air-gapped or fully internal clusters |

The recommended approach for the HomericIntelligence mesh is the self-signed internal CA (`step ca init`), as it works for all Tailscale IPs, does not require public DNS, and keeps the entire PKI under team control.

## Consequences

**Positive:**
- All NATS payloads (agent events, task updates, coordination messages) are encrypted in transit at the application layer, independent of network-layer controls.
- Leafnode connections now target the correct port (7422), resolving the connection failure documented in issue #5.
- Cert path convention (`/etc/nats/certs/`) is documented and consistent across all TLS blocks, simplifying operator tooling.
- Defense-in-depth: a compromised Tailscale node or a routing misconfiguration no longer exposes NATS message content.

**Negative:**
- Operators must provision TLS certificates before starting NATS. This adds an onboarding step that was not previously required.
- NATS servers will refuse to start if cert files are absent or unreadable — this is intentional (fail-closed), but may surprise operators used to the old config.
- Existing plain-`nats://` client connections will be rejected by the updated server config; all clients must switch to `nats+tls://` or the NATS client TLS option.

**Neutral:**
- The monitoring endpoint remains HTTP on loopback — no change in behavior, only an explicit comment clarifying the intent.
- Cert rotation must be handled operationally (e.g., cron job or systemd timer to reload NATS after cert renewal). This is standard TLS operational overhead.
- The `cluster.routes` comment (for multi-server clusters) is preserved; route TLS will automatically apply when routes are configured.

## References

- [ADR 002](002-nats-event-bridge.md) — Decision to use NATS JetStream as the event bridge
- [ADR 005](005-nats-subject-schema.md) — NATS subject schema that rides on top of these connections
- [Issue #32](https://github.com/HomericIntelligence/Odysseus/issues/32) — Audit finding: NATS inter-service communication lacks TLS encryption
- [Issue #5](https://github.com/HomericIntelligence/Odysseus/issues/5) — Leafnode port mismatch (resolved as part of this ADR)
- [NATS TLS documentation](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/tls)
- [Smallstep `step` CLI](https://smallstep.com/docs/step-cli/) — Recommended tool for internal CA provisioning
