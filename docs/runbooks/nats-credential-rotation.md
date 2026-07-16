# Runbook: NATS Credential Rotation and Compromise Response

This runbook covers the **operational lifecycle** of the NATS mutual-TLS credentials after
they are first provisioned:

1. **Routine rotation** of a single role's client cert (rolling, mesh stays up).
2. **CA rotation** (the trust anchor at `/etc/nats/certs/ca.pem`).
3. **Suspected compromise / revocation** of a leaked role cert (incident response).

Enabling mTLS auth for the first time is a separate, already-documented procedure — see
[enable-nats-auth](enable-nats-auth.md). This runbook assumes that setup is already in place:
per-role SAN certs under `/etc/nats/certs/clients/`, the CA at `/etc/nats/certs/ca.pem`, and
`verify_and_map = true` enforced on the client listener per
[ADR-010](../adr/010-nats-mtls-subject-scoped-auth.md).

Terminology and the cert identity model here are aligned with
[ADR-008](../adr/008-nats-tls-encryption.md) (TLS),
[ADR-009](../adr/009-nats-authentication.md) (authentication), and
[ADR-010](../adr/010-nats-mtls-subject-scoped-auth.md) (mTLS + subject-scoped accounts).

---

## How revocation actually works in this setup (read first)

This is the single most important fact for everything below, so it is stated up front.

The canonical [`configs/nats/server.conf`](../../configs/nats/server.conf) and
[`configs/nats/leaf.conf`](../../configs/nats/leaf.conf) **do not configure a CRL (Certificate
Revocation List) or OCSP**. NATS authenticates a client by:

1. Verifying the presented cert chains to the CA in `/etc/nats/certs/ca.pem`
   (`verify_and_map = true`), then
2. Mapping the cert's **DNS SAN** to an account `user` in the `accounts {}` allow-list.

There is no online revocation check. As a direct consequence, a cert stops being accepted
**only** when one of the following is true:

- The **CA that signed it is no longer trusted** (its entry is gone from `ca.pem` on every
  server) — see [CA rotation](#part-2-ca-rotation) and
  [compromise response](#part-3-suspected-compromise--revocation), OR
- The cert's **SAN-DNS identity is removed from the `accounts {}` allow-list** in
  `server.conf`/`leaf.conf` (the account `user` value it maps to no longer exists), OR
- The cert has **expired** (past its `notAfter`).

**Restarting NATS drops all existing TLS sessions**, forcing every client to re-handshake
against the current config and CA. Simply re-issuing a fresh cert for a role does **not** by
itself invalidate the old one — the old cert keeps working until it expires or one of the
conditions above is met. Plan every procedure below around this reality; do not assume a
"revoke" verb exists.

> **Assumption (documented):** No CRL/OCSP is configured in the ground-truth configs as of the
> current submodule pin. If a future ADR adds `ca_file` + a CRL/OCSP stapling mechanism to the
> `tls {}` blocks, the revocation steps in [Part 3](#part-3-suspected-compromise--revocation)
> should be revisited. Until then, revocation = re-issue the CA and/or remove the identity from
> the allow-list, then restart. This runbook documents the honest procedure for the config that
> exists, not a hypothetical CRL flow.

---

## Prerequisites

- The `step` CLI installed: <https://smallstep.com/docs/step-cli/>.
- Access to the internal CA (or its offline signing key) provisioned per
  [ADR-008](../adr/008-nats-tls-encryption.md) (`step ca init`).
- `openssl` available on each host for cert inspection.
- SSH/`scp` reachability to every host over Tailscale (cert distribution channel, per
  [enable-nats-auth](enable-nats-auth.md) Step 2).
- The role → host → cert mapping from
  [enable-nats-auth](enable-nats-auth.md) Step 2 (reproduced here for convenience):

| Host | Services | Certs |
|------|----------|-------|
| Primary (epimetheus) | NATS hub, Hermes | `hermes-cert.pem`, `hermes-key.pem` |
| Control host | Agamemnon, Telemachy | `telemachy-cert.pem`, `telemachy-key.pem` |
| Worker hosts | Myrmidon agents | `agent-cert.pem`, `agent-key.pem` |
| Keystone hosts | Keystone | `keystone-cert.pem`, `keystone-key.pem` |

---

## Part 0: Check Certificate Expiry

Run this on any host that holds role certs, or against the CA, to see what is expiring. Do this
on a schedule (e.g. a weekly cron / systemd timer) so rotation happens **before** expiry, not
after a fail-closed outage.

Inspect a single cert's validity window:

```bash
# Human-readable validity window
step certificate inspect /etc/nats/certs/clients/hermes-cert.pem \
  --format json | python3 -c 'import sys,json;d=json.load(sys.stdin)["validity"];print("not_after:",d["end"])'

# openssl equivalent (no step required)
openssl x509 -noout -enddate -in /etc/nats/certs/clients/hermes-cert.pem
# Output: notAfter=<date>
```

Fail-fast expiry check (exit non-zero if a cert expires within 30 days):

```bash
for c in /etc/nats/certs/clients/*-cert.pem /etc/nats/certs/ca.pem /etc/nats/certs/server-cert.pem; do
  if openssl x509 -checkend $((30*24*3600)) -noout -in "$c" >/dev/null 2>&1; then
    echo "OK    $c"
  else
    echo "RENEW $c  (expires within 30 days)"
  fi
done
```

**Suggested cadence.** The `step` CLI default client-cert lifetime is short (24h) unless the CA
provisioner sets a longer `--not-after`. For a long-running mesh, issue role certs with an
explicit lifetime and rotate on a fixed fraction of it:

- **Role client certs (hermes/agent/keystone/telemachy):** issue with
  `--not-after=2160h` (90 days); rotate at **60 days** (⅔ of lifetime), leaving a 30-day margin.
- **Server/leaf node certs (`server-cert.pem`):** same 90-day / 60-day cadence.
- **CA (`ca.pem`):** long-lived (issued once at `step ca init`, typically 10 years). Rotate
  only on planned PKI refresh or on compromise — see [Part 2](#part-2-ca-rotation).

Adjust the numbers to whatever `--not-after` your CA provisioner actually issues; the rule is
"rotate at ⅔ of the lifetime, alarm at 30 days remaining."

---

## Part 1: Routine Rotation of One Role's Client Cert

This is a **rolling, per-role** operation. Because each role is an independent TLS identity,
you rotate one role at a time and the rest of the mesh keeps running. Repeat the whole part for
each role on its own cadence.

Throughout this part, `<role>` is one of `hermes`, `agent`, `keystone`, `telemachy` (or
`server` for a node cert). The SAN-DNS identity is `<role>.homeric` and **must not change**
during a routine rotation — the `accounts {}` allow-list in `server.conf`/`leaf.conf` maps that
exact string, so a new cert must reuse the same CN + SAN to keep mapping to the same account.

### Step 1: Re-issue the role cert

On the host where the CA key is accessible (or via `step ca certificate` against a live CA),
issue a fresh cert for the same identity. Write to a temp path first so the live cert is not
disturbed until you deploy it:

```bash
ROLE=hermes            # one of: hermes | agent | keystone | telemachy | server
TMP=$(mktemp -d)

step ca certificate "${ROLE}.homeric" \
  "${TMP}/${ROLE}-cert.pem" \
  "${TMP}/${ROLE}-key.pem" \
  --san "${ROLE}.homeric" \
  --not-after=2160h        # 90 days; match your chosen cadence
```

Verify the new cert carries the required DNS SAN (the `verify_and_map` match key — a bare CN is
never sufficient, per [ADR-010](../adr/010-nats-mtls-subject-scoped-auth.md) §2):

```bash
openssl x509 -noout -ext subjectAltName -in "${TMP}/${ROLE}-cert.pem"
# Expected output must include: DNS:hermes.homeric  (for ROLE=hermes)
```

### Step 2: Deploy the new cert to the role's host(s)

Copy the new cert+key to `/etc/nats/certs/clients/` on each host that runs this role (see the
Prerequisites table). Preserve the existing permissions convention: cert `644`, key `600`.

```bash
# Example: deploy the new hermes cert to the primary host over Tailscale
scp "${TMP}/${ROLE}-"{cert,key}.pem \
  100.92.173.32:/etc/nats/certs/clients/

# On the destination host, fix permissions
ssh 100.92.173.32 'chmod 644 /etc/nats/certs/clients/'"${ROLE}"'-cert.pem && \
                    chmod 600 /etc/nats/certs/clients/'"${ROLE}"'-key.pem'
```

Because clients read the cert files at connect time, overwriting the files does not affect the
already-open connection until the client reconnects (next step). Keep a backup of the previous
cert+key for the rollback path:

```bash
ssh 100.92.173.32 'cp /etc/nats/certs/clients/'"${ROLE}"'-cert.pem \
                      /etc/nats/certs/clients/'"${ROLE}"'-cert.pem.bak'
```

### Step 3: Reload / restart only the client for that role

The **NATS server** does not need to restart for a client-cert rotation — only the client
process that presents the cert. Restart just that one service so it re-handshakes with the new
cert:

```bash
# Hermes (systemd example)
sudo systemctl restart hermes
# or podman:  podman restart hermes

# Agent workers (Myrmidons): restart the agent worker process/container
# Keystone / Telemachy: restart their respective service units
```

For a **server/leaf node cert** (`server-cert.pem`) rotation, the NATS server itself must pick
up the new cert. NATS supports a config reload without dropping the process:

```bash
# Reload NATS in place (re-reads cert files; does not drop the whole VM)
nats-server --signal reload
# or send SIGHUP to the nats-server PID
```

> **Note:** `--signal reload` re-reads the TLS material. Existing client TLS sessions are
> **not** forcibly torn down by a reload, so a node-cert rotation is graceful. A full restart
> (which *does* drop sessions) is only required for the revocation path in
> [Part 3](#part-3-suspected-compromise--revocation).

### Step 4: Verify the role reconnected with the new cert

```bash
CERTS="/etc/nats/certs/clients"
CA="/etc/nats/certs/ca.pem"
HUB="tls://127.0.0.1:4222"

# 1. The new cert can connect and exercise its account's permissions.
#    (hermes example — publish is allowed for HERMES; use a subject in-scope for your role)
nats --server "$HUB" \
  --tlscert "$CERTS/${ROLE}-cert.pem" \
  --tlskey  "$CERTS/${ROLE}-key.pem" \
  --tlsca   "$CA" \
  pub hi.rotation.check "rotated-$(date -u +%FT%TZ)" \
  && echo "PASS: ${ROLE} reconnected with new cert" \
  || echo "FAIL: ${ROLE} could not connect with new cert"

# 2. For Hermes specifically, confirm the health endpoint is green (it reconnected).
curl -sf http://localhost:8085/health | grep -q '"status"' \
  && echo "PASS: Hermes healthy after rotation" \
  || echo "FAIL: Hermes health check failed after rotation"

# 3. Confirm the serial number changed (proves the NEW cert is in use, not the old one).
openssl x509 -noout -serial -in "$CERTS/${ROLE}-cert.pem"
```

Repeat Part 1 for each role. Once all roles are on fresh certs, remove the `.bak` backups.

### Rollback (routine rotation)

If the role fails to connect with the new cert (Step 4 FAIL), restore the backup and restart
the client — the mesh returns to the previous working cert with no server change:

```bash
ssh 100.92.173.32 'mv /etc/nats/certs/clients/'"${ROLE}"'-cert.pem.bak \
                      /etc/nats/certs/clients/'"${ROLE}"'-cert.pem'
sudo systemctl restart "${ROLE}"     # restart the client so it re-presents the old cert
```

Then diagnose the new cert with `openssl x509 -noout -ext subjectAltName -in <new-cert>` and
confirm the DNS SAN exactly matches the `accounts {}` `user` value.

---

## Part 2: CA Rotation

Rotating the CA (`/etc/nats/certs/ca.pem`) is the trust anchor for **every** cert in the mesh,
so it is materially harder than a single role cert. Read this section fully before starting.

### Can this be zero-downtime?

**Partly — with an honest caveat.** NATS `ca_file` accepts a **bundle** (multiple concatenated
CA certificates). That makes a **dual-trust window** possible: you can trust both the old and
the new CA simultaneously, migrate every leaf/role cert to the new CA, then drop the old CA.
During that window, clients presenting *either* the old-CA or new-CA cert are accepted.

**The honest caveat:** a NATS server only re-reads `ca_file` on **reload/restart**, and a
cluster/leaf topology has multiple servers (hub + leaf nodes). A CA roll therefore requires a
**coordinated reload of every NATS server** in the mesh, and the ordering matters (widen trust
everywhere *before* any cert is re-signed under the new CA only). It is **not** a single-command
zero-downtime operation. Treat it as a **scheduled maintenance window** with the dual-trust
sequence below; expect brief per-server reload blips, but no full outage if the ordering holds.

If you cannot guarantee coordinated reloads across all servers (e.g. leaf hosts are
unreachable), fall back to the
[full maintenance-window path](#option-b-full-maintenance-window-ca-rotation-fallback) instead.

### Option A: Dual-trust rolling CA rotation (preferred)

**Phase 1 — Widen trust (add the new CA alongside the old).**

```bash
# 1. Create the new CA (or new intermediate) with step, OFFLINE — do not touch live hosts yet.
#    Keep new-ca.pem and its key secure.

# 2. Build a bundle that trusts BOTH old and new CA.
cat /etc/nats/certs/ca.pem  new-ca.pem  > /tmp/ca-bundle.pem

# 3. Distribute the bundle to EVERY host as /etc/nats/certs/ca.pem, then reload EVERY NATS
#    server (hub first, then each leaf). At this point both CAs are trusted everywhere.
scp /tmp/ca-bundle.pem <host>:/etc/nats/certs/ca.pem      # repeat for every host
ssh <host> 'nats-server --signal reload'                  # repeat for every NATS server
```

Verify every server now trusts both CAs before proceeding — a role cert signed by the new CA
must be accepted while old-CA certs still work.

**Phase 2 — Migrate every cert to the new CA.**

Re-issue **each** role cert and each server/leaf node cert under the **new** CA, reusing the
same SAN-DNS identity, using the [Part 1](#part-1-routine-rotation-of-one-roles-client-cert)
rolling procedure per role. Because trust is dual during this phase, each role can be migrated
independently with no coordination — old-CA and new-CA certs coexist.

**Phase 3 — Narrow trust (drop the old CA).**

Once **every** role and node cert has been re-issued under the new CA and verified:

```bash
# Replace the bundle with ONLY the new CA.
cp new-ca.pem /etc/nats/certs/ca.pem      # on every host
nats-server --signal reload               # on every NATS server (hub first, then leaves)
```

After Phase 3, any cert still signed by the old CA is rejected. This is also the mechanism that
**revokes** a compromised cert when you must invalidate an entire CA (see Part 3).

### Option B: Full maintenance-window CA rotation (fallback)

Use this if you cannot guarantee coordinated dual-trust reloads (e.g. some leaf hosts are
offline, or the setup does not permit a bundle roll cleanly).

1. Announce a maintenance window; expect the `hi.*` event pipeline to be down for its duration.
2. Stop every NATS client (Hermes, agents, Keystone, Telemachy) and every NATS server
   (leaves first, then hub).
3. Replace `/etc/nats/certs/ca.pem` with the new CA on **every** host.
4. Re-issue **all** role certs and all `server-cert.pem`/leaf node certs under the new CA
   (same SAN-DNS identities), distribute to their hosts.
5. Start the hub NATS server, then each leaf, then each client
   (follow [enable-nats-auth](enable-nats-auth.md) Step 4 for the start commands).
6. Run the full [verification](#part-4-verification-summary) below.

### Verify CA rotation

```bash
# The active CA on a host — confirm it is the NEW CA (check issuer / fingerprint).
openssl x509 -noout -issuer -fingerprint -in /etc/nats/certs/ca.pem

# A freshly-issued (new-CA) role cert must connect...
nats --server tls://127.0.0.1:4222 \
  --tlscert /etc/nats/certs/clients/hermes-cert.pem \
  --tlskey  /etc/nats/certs/clients/hermes-key.pem \
  --tlsca   /etc/nats/certs/ca.pem \
  pub hi.rotation.cacheck ok \
  && echo "PASS: new-CA cert accepted" || echo "FAIL: new-CA cert rejected"

# ...and (after Phase 3 / Option B) an OLD-CA cert must be REJECTED.
# Keep one archived old-CA cert to prove the old trust anchor is gone:
nats --server tls://127.0.0.1:4222 \
  --tlscert /tmp/old-ca-hermes-cert.pem \
  --tlskey  /tmp/old-ca-hermes-key.pem \
  --tlsca   /etc/nats/certs/ca.pem \
  pub hi.rotation.cacheck should-fail 2>&1 \
  | grep -qiE "tls|certificate|unknown ca" \
  && echo "PASS: old-CA cert rejected" || echo "FAIL: old-CA cert STILL accepted"
```

### Rollback (CA rotation)

- **During Option A Phase 1/2** (old CA still in the bundle): revert `ca.pem` to the old-only
  CA and reload; all old-CA certs still work. Low risk.
- **After Phase 3 / Option B** (old CA dropped): rollback means restoring the old `ca.pem`
  bundle **and** the old certs on every host, then reloading/restarting. Keep the old CA and a
  snapshot of the old certs until the new PKI is fully verified for at least one rotation cycle.

---

## Part 3: Suspected Compromise / Revocation

Use this when a role's private key is believed leaked (see [Detect](#detect) for signals). The
goal: make the compromised cert **unable to connect**, re-issue a clean cert for the role, and
restore secure operation. Given the no-CRL reality stated at the top, "revoke" here means one
of two mechanisms depending on blast radius.

### Detect

Signals that a role cert / key may be compromised:

- A `-key.pem` file found with wrong permissions (world-readable), in a git commit, in a
  container image layer, in a log, or copied off-host.
- Unexpected connections in NATS monitoring: on the hub, check
  `curl -s http://127.0.0.1:8222/connz | python3 -m json.tool` for connections from an
  unexpected IP presenting a known role identity, or a higher-than-expected connection count
  for a role.
- `AuthorizationError` / "permissions violation" spikes in Hermes logs from a role that should
  not be hitting those subjects (a stolen cert probing beyond its scope).
- Any host running a role is itself compromised — treat its cert+key as leaked.

### Step 1: Contain — decide the blast radius

There are two revocation mechanisms available in this (no-CRL) setup. Pick based on scope:

| Situation | Mechanism | Effect |
|-----------|-----------|--------|
| One role's key leaked; you can tolerate that **role identity** being briefly denied | **Remove the role's identity from the `accounts {}` allow-list**, restart NATS | Denies **every** cert mapping to that SAN-DNS (old *and* new) until you re-add it. Precise to one role. |
| Broad compromise, or you cannot tell which certs are affected, or the CA key itself may be exposed | **Rotate the CA** (Part 2) | Invalidates **all** old-CA certs at once. Largest hammer. |

For a single leaked role key where you want to keep that role running on a **new** cert, the
cleanest sequence is: re-issue the role cert **and** rotate the CA (so the leaked cert's signer
is no longer trusted). If a full CA roll is too heavy for the incident, use the allow-list
removal as an **immediate** stop-gap, re-issue, then schedule a CA roll.

### Step 2: Immediate revocation (allow-list removal — fastest stop-gap)

This denies the compromised identity in seconds without a CA roll. Edit the canonical configs,
push to every server, restart to drop existing sessions.

```bash
ROLE=agent     # the compromised role
```

1. In [`configs/nats/server.conf`](../../configs/nats/server.conf) **and**
   [`configs/nats/leaf.conf`](../../configs/nats/leaf.conf), comment out or remove the
   `accounts {}` entry whose `user = "<role>.homeric"` (e.g. the `AGENTS` account for
   `agent.homeric`). With that identity gone from the allow-list, `verify_and_map` has nothing
   to map the compromised cert to, and the connection is rejected — **even though the cert is
   still validly signed by the CA.**
2. Distribute the edited config to every NATS server host.
3. **Restart** (not just reload) every NATS server so existing TLS sessions are torn down and
   the attacker's live connection is dropped:

   ```bash
   sudo systemctl restart nats        # hub, then each leaf
   # or podman: podman restart nats-server / nats-leaf
   ```

> **Why restart, not reload:** a reload re-reads config for *new* connections but an attacker's
> **already-established** session can survive. A restart forces every client to re-handshake and
> re-authorize against the config with the identity removed, dropping the compromised session.

This stop-gap denies the whole role (legitimate instances too) until Step 3 restores it on a
clean identity — accept that brief role outage as the containment cost.

### Step 3: Re-issue a clean cert for the role

Issue a fresh cert for the same SAN-DNS identity (per [Part 1](#step-1-re-issue-the-role-cert)),
deploy it to the role's legitimate host(s), and **re-add** the account entry you removed in
Step 2 (restore the `accounts {}` block in both configs). Restart the servers again so the
restored identity is live, then restart the legitimate role client so it presents the new cert.

If the CA key itself may be compromised, **do not** stop at re-issue — proceed to a full
[CA rotation](#part-2-ca-rotation) (Option A dual-trust, or Option B window). Re-issuing under a
compromised CA gives no security, because the attacker can mint their own certs.

### Step 4: Rotate any shared secrets touched by the incident

mTLS role certs are not the only credentials. If the compromised host also held the shared
bootstrap secrets referenced in the configs, rotate them too:

- **`$NATS_LEAF_TOKEN`** (leaf → hub bootstrap auth, [`leaf.conf`](../../configs/nats/leaf.conf)
  remotes / [ADR-009](../adr/009-nats-authentication.md)): generate a new token, update it in
  deployment secrets on the hub and every leaf, restart.
- **`$NATS_LEAF_USER` / `$NATS_LEAF_PASSWORD`** (leafnode listener authorization in
  [`server.conf`](../../configs/nats/server.conf)): rotate the same way.
- **`$NATS_CLUSTER_USER` / `$NATS_CLUSTER_PASSWORD`** (cluster route authorization,
  [ADR-009](../adr/009-nats-authentication.md)): rotate on every cluster peer (must match).
- **`$NATS_MONITORING_PASSWORD`** if the monitoring authorization block is enabled.

For per-leaf `.creds` (NKey/JWT) files — the recommended path in
[ADR-009](../adr/009-nats-authentication.md) — a leaked `.creds` is revoked by re-issuing that
leaf's creds from your operator/account JWT flow and updating
`/etc/nats/certs/leaf.creds` on that leaf; per-leaf creds give individual revocation without
rotating a shared token.

### Step 5: Verify the compromised cert can no longer connect

Keep a copy of the compromised cert+key (or reproduce the attacker's position) and prove it is
now denied:

```bash
CA="/etc/nats/certs/ca.pem"
HUB="tls://127.0.0.1:4222"

# The COMPROMISED cert MUST now be rejected.
nats --server "$HUB" \
  --tlscert /tmp/compromised-cert.pem \
  --tlskey  /tmp/compromised-key.pem \
  --tlsca   "$CA" \
  pub hi.compromise.check should-fail 2>&1 \
  | grep -qiE "tls|certificate|authorization|permissions|unknown ca|no account" \
  && echo "PASS: compromised cert rejected" \
  || echo "FAIL: compromised cert STILL connects — DO NOT stand down"

# The NEW legitimate cert MUST connect (role restored).
nats --server "$HUB" \
  --tlscert /etc/nats/certs/clients/${ROLE}-cert.pem \
  --tlskey  /etc/nats/certs/clients/${ROLE}-key.pem \
  --tlsca   "$CA" \
  pub hi.compromise.check ok \
  && echo "PASS: ${ROLE} restored on new cert" \
  || echo "FAIL: ${ROLE} cannot connect on new cert"

# Confirm no stale attacker session lingers on the hub.
curl -s http://127.0.0.1:8222/connz | python3 -c \
  'import sys,json;print("open connections:",json.load(sys.stdin)["num_connections"])'
```

Do **not** consider the incident closed until the first check outputs `PASS` (compromised cert
rejected) **and** the connection list shows no unexpected sessions.

### Rollback (compromise response)

Compromise response is intentionally one-directional — you are removing trust, so "rollback"
means restoring service, not restoring the compromised cert:

- If the allow-list removal (Step 2) broke a **legitimate** role because the re-issue was not
  ready, restore the `accounts {}` block from git and restart to bring the role back on its
  **existing** cert as an interim measure — but only if that cert is confirmed *not* the leaked
  one. Never re-trust the leaked cert/CA.
- Keep the pre-incident configs in git history; a `git show HEAD~1:configs/nats/server.conf`
  gives the exact prior allow-list if you need to compare.

---

## Part 4: Verification (summary)

After **any** procedure in this runbook, confirm the mesh is healthy end-to-end. This section
mirrors [enable-nats-auth](enable-nats-auth.md) Step 5:

```bash
CERTS="/etc/nats/certs/clients"
CA="/etc/nats/certs/ca.pem"
HUB="tls://127.0.0.1:4222"

# 1. Anonymous connect still rejected (auth is intact).
nats --server "$HUB" pub hi.test x 2>&1 \
  | grep -qiE "tls|certificate|authorization required" \
  && echo "PASS: anonymous connect rejected" \
  || echo "FAIL: anonymous connect NOT rejected"

# 2. Hermes can still create/inspect a JetStream stream (event pipeline alive).
nats --server "$HUB" \
  --tlscert "$CERTS/hermes-cert.pem" --tlskey "$CERTS/hermes-key.pem" --tlsca "$CA" \
  stream ls >/dev/null \
  && echo "PASS: HERMES account operational" || echo "FAIL: HERMES account broken"

# 3. Subject-scope boundary still enforced (AGENTS denied hi.tasks.>).
nats --server "$HUB" \
  --tlscert "$CERTS/agent-cert.pem" --tlskey "$CERTS/agent-key.pem" --tlsca "$CA" \
  sub "hi.tasks.>" 2>&1 | grep -qiE "permissions violation" \
  && echo "PASS: AGENTS scope boundary enforced" \
  || echo "FAIL: AGENTS scope boundary NOT enforced"

# 4. Hermes health endpoint green.
curl -sf http://localhost:8085/health | grep -q '"status"' \
  && echo "PASS: Hermes healthy" || echo "FAIL: Hermes health check failed"
```

All checks must print `PASS`. For a leaf-attached mesh, also re-run the leaf → hub propagation
check from [enable-nats-auth](enable-nats-auth.md) Step 5 (check 5).

---

## References

- [enable-nats-auth](enable-nats-auth.md) — first-time mTLS auth setup (cert issuance, config,
  enforcement). This runbook is its operational-lifecycle companion.
- [ADR-008](../adr/008-nats-tls-encryption.md) — TLS for all NATS links; `/etc/nats/certs/`
  convention; cert rotation noted as operational overhead.
- [ADR-009](../adr/009-nats-authentication.md) — authentication on every listener; shared
  bootstrap tokens vs per-leaf revocable `.creds`.
- [ADR-010](../adr/010-nats-mtls-subject-scoped-auth.md) — mTLS `verify_and_map`, SAN-DNS
  identity contract, subject-scoped `accounts {}`.
- [`configs/nats/server.conf`](../../configs/nats/server.conf),
  [`configs/nats/leaf.conf`](../../configs/nats/leaf.conf) — ground-truth config (no CRL/OCSP;
  allow-list + CA trust are the revocation levers).
- [Smallstep `step` CLI](https://smallstep.com/docs/step-cli/) — cert issuance/inspection.
- [NATS TLS documentation](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/tls)
