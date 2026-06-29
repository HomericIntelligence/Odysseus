# Runbook: Enable NATS Mutual-TLS Authentication and Authorization

This runbook enables the `verify_and_map` authentication and subject-scoped `accounts {}`
authorization defined in ADR-010. Follow these steps top-to-bottom on every host before
restarting NATS with the updated `configs/nats/server.conf` and `configs/nats/leaf.conf`.

**CRITICAL:** Steps 1–3 must be completed and verified **before** restarting NATS in step 4.
NATS with `verify_and_map = true` is fail-closed — all existing plain `nats://` connections
will be rejected as soon as the new config is loaded.

---

## Prerequisites

- An internal CA provisioned per ADR-008 (`step ca init`). The CA must be reachable or its
  offline key must be available to sign role certs.
- The `step` CLI installed: <https://smallstep.com/docs/step-cli/>
- `/etc/nats/certs/ca.pem` deployed on all hosts (existing, from ADR-008 TLS setup).

---

## Step 1: Issue One SAN Cert Per Role

For each role that will run on your mesh, issue a client cert with both a matching CN and a
DNS Subject Alternative Name. The SAN-DNS value is the key used by NATS `verify_and_map` to
look up the account user — a bare CN is never sufficient.

Run the following on the host where the CA key is accessible (or via `step ca certificate`
against a live CA):

```bash
# Directory to hold role certs
mkdir -p /etc/nats/certs/clients
chmod 700 /etc/nats/certs/clients

# Hermes (event bridge, stream creator)
step ca certificate hermes.homeric \
  /etc/nats/certs/clients/hermes-cert.pem \
  /etc/nats/certs/clients/hermes-key.pem \
  --san hermes.homeric

# Agent workers (Myrmidons)
step ca certificate agent.homeric \
  /etc/nats/certs/clients/agent-cert.pem \
  /etc/nats/certs/clients/agent-key.pem \
  --san agent.homeric

# Keystone (DAG consumer)
step ca certificate keystone.homeric \
  /etc/nats/certs/clients/keystone-cert.pem \
  /etc/nats/certs/clients/keystone-key.pem \
  --san keystone.homeric

# Telemachy (workflow runner)
step ca certificate telemachy.homeric \
  /etc/nats/certs/clients/telemachy-cert.pem \
  /etc/nats/certs/clients/telemachy-key.pem \
  --san telemachy.homeric

# System account (NATS internal — issue if needed for system-level tooling)
step ca certificate sys.homeric \
  /etc/nats/certs/clients/sys-cert.pem \
  /etc/nats/certs/clients/sys-key.pem \
  --san sys.homeric

# Fix permissions
chmod 644 /etc/nats/certs/clients/*-cert.pem
chmod 600 /etc/nats/certs/clients/*-key.pem
```

**Verify each cert carries the DNS SAN:**

```bash
openssl x509 -noout -ext subjectAltName \
  -in /etc/nats/certs/clients/hermes-cert.pem
# Expected output must include: DNS:hermes.homeric
```

---

## Step 2: Distribute Role Certs to Each Host

Copy the relevant role cert(s) to `/etc/nats/certs/clients/` on each host that runs the
corresponding service:

| Host | Services | Certs needed |
|------|----------|--------------|
| Primary (epimetheus) | NATS hub, Hermes | `hermes-cert.pem`, `hermes-key.pem` |
| Control host | Agamemnon, Telemachy | `telemachy-cert.pem`, `telemachy-key.pem` |
| Worker hosts | Myrmidon agents | `agent-cert.pem`, `agent-key.pem` |
| Keystone hosts | ProjectKeystone | `keystone-cert.pem`, `keystone-key.pem` |

Use `scp` over Tailscale or your secret-distribution tool (ProjectKeystone / Myrmidons):

```bash
# Example: distribute Hermes cert to the primary host
scp /etc/nats/certs/clients/hermes-{cert,key}.pem \
  100.92.173.32:/etc/nats/certs/clients/
```

---

## Step 3: Configure Each Client to Use TLS and Present Its Cert

Configure each downstream service **before** restarting NATS. The table below maps each
service to the environment variables that enable mTLS. Set these in your deployment secrets,
systemd unit `[Service]` block, or compose `.env` file.

> **Note on ProjectTelemachy:** The `require_tls` gate in
> `provisioning/ProjectTelemachy/src/telemachy/config.py` rejects plain `nats://` when
> `REQUIRE_TLS=true` but does not yet load a client cert. Client-cert wiring for Telemachy
> is tracked as a follow-up issue ("ProjectTelemachy: add NATS client-cert (mTLS) wiring").
> Telemachy cannot connect to a `verify_and_map`-enforced NATS until that issue is resolved.

| Service | Environment variables |
|---------|----------------------|
| **ProjectHermes** (`infrastructure/ProjectHermes/src/hermes/config.py:34`) | `NATS_URL=tls://<hub-tailscale-ip>:4222`<br>`TLS_CERT_FILE=/etc/nats/certs/clients/hermes-cert.pem`<br>`TLS_KEY_FILE=/etc/nats/certs/clients/hermes-key.pem`<br>`TLS_CA_BUNDLE=/etc/nats/certs/ca.pem` |
| **ProjectTelemachy** (`provisioning/ProjectTelemachy/src/telemachy/config.py:21`) | `NATS_URL=tls://<hub-tailscale-ip>:4222`<br>`REQUIRE_TLS=true`<br>*(client-cert wiring pending — see note above)* |
| **compose bridge** (`docker-compose.crosshost.yml:45`) | `NATS_URL=tls://nats:4222`<br>Mount `telemachy-cert.pem` / `telemachy-key.pem` into the container and set the corresponding `TLS_CERT_FILE` / `TLS_KEY_FILE` env vars. |

Hermes is already mTLS-capable (`config.py:102-105` defines `tls_cert_file`, `tls_key_file`,
`tls_ca_bundle`; `config.py:126 build_ssl_context()` activates when cert+key are set). Only
the environment variables above are required — no code changes needed for Hermes.

**PREREQUISITE: Provision the `hermes.homeric` cert before enabling enforcement.**
Hermes creates JetStream streams (`homeric-agents`, `homeric-tasks`) on startup. If the
Hermes cert is absent when NATS enforcement is activated, streams will not be created and the
entire `hi.*` event pipeline will be inoperative.

---

## Step 4: Restart NATS with the New Config

On the **primary** NATS host (`server.conf`):

```bash
# If running via podman
podman stop nats-server
podman run -d \
  --name nats-server \
  --network homeric-mesh \
  -p 4222:4222 \
  -p 6222:6222 \
  -p 7422:7422 \
  -v /etc/nats/certs:/etc/nats/certs:ro \
  -v $(pwd)/configs/nats/server.conf:/etc/nats/server.conf:ro \
  nats:3.12.0 -c /etc/nats/server.conf

# If running nats-server natively
sudo systemctl restart nats
```

On each **leaf node** host (`leaf.conf`):

```bash
podman stop nats-leaf
podman run -d \
  --name nats-leaf \
  --network homeric-mesh \
  -p 4222:4222 \
  -v /etc/nats/certs:/etc/nats/certs:ro \
  -v $(pwd)/configs/nats/leaf.conf:/etc/nats/server.conf:ro \
  nats:3.12.0 -c /etc/nats/server.conf
```

Check logs for startup errors:

```bash
podman logs nats-server 2>&1 | grep -iE "error|fatal|tls|account"
```

Expected: `Server is ready for connections on 0.0.0.0:4222` with no TLS/account errors.

---

## Step 5: Functional Verification

Run these checks against the running hardened NATS server to confirm auth enforcement:

```bash
HUB="tls://127.0.0.1:4222"
CERTS="/etc/nats/certs/clients"
CA="/etc/nats/certs/ca.pem"

# 1. Anonymous connect MUST be rejected (no client cert)
nats --server "$HUB" pub hi.test x 2>&1 \
  | grep -qiE "tls|certificate|authorization required" \
  && echo "PASS: anonymous connect rejected" \
  || echo "FAIL: anonymous connect was NOT rejected"

# 2. hermes.homeric cert MUST be able to create a JetStream stream
nats --server "$HUB" \
  --tlscert "$CERTS/hermes-cert.pem" \
  --tlskey  "$CERTS/hermes-key.pem" \
  --tlsca   "$CA" \
  stream add homeric-agents-test \
  --subjects "hi.agents.>" \
  --defaults \
  && echo "PASS: HERMES account can create a stream" \
  || echo "FAIL: HERMES stream creation failed"

# 3. agent.homeric cert MUST be denied subscribing to hi.tasks.> (not in AGENTS subscribe allow-list)
#    AGENTS subscribe allow = ["hi.agents.>", "_INBOX.>"]; hi.tasks.> is genuinely
#    outside that list, so this verifies the allow-list boundary is enforced.
nats --server "$HUB" \
  --tlscert "$CERTS/agent-cert.pem" \
  --tlskey  "$CERTS/agent-key.pem" \
  --tlsca   "$CA" \
  sub "hi.tasks.>" 2>&1 \
  | grep -qiE "permissions violation" \
  && echo "PASS: AGENTS account denied hi.tasks.> (allow-list boundary enforced)" \
  || echo "FAIL: AGENTS account was NOT denied hi.tasks.> (allow-list not enforced)"

# 4. Hermes health endpoint (proves Hermes reconnected with its cert)
curl -sf http://localhost:8085/health | grep -q '"status"' \
  && echo "PASS: Hermes healthy (reconnected with client cert)" \
  || echo "FAIL: Hermes health check failed"

# 5. LEAF -> HUB PROPAGATION (run only on hosts with a leaf node)
#    With named accounts{}, each leafnode remote bridges exactly ONE account, so the
#    leaf.conf remotes block must carry one entry per account with an explicit
#    `account:` binding. This check proves a leaf-attached AGENTS client's hi.agents.>
#    events actually reach the hub — the gap a missing per-account remote would leave
#    silently uncaught. Subscribe on the HUB, publish from the LEAF.
LEAF="tls://127.0.0.1:4222"   # local leaf node client port
HUB="tls://100.92.173.32:4222" # primary hub client port (update to your hub IP)
AGENT_TLS=(--tlscert "$CERTS/agent-cert.pem" --tlskey "$CERTS/agent-key.pem" --tlsca "$CA")

# Subscribe on the HUB for one message, in the background
nats --server "$HUB" "${AGENT_TLS[@]}" sub "hi.agents.leafcheck" --count 1 > /tmp/leafcheck.out 2>&1 &
SUB_PID=$!
sleep 1
# Publish from the LEAF node's local client port
nats --server "$LEAF" "${AGENT_TLS[@]}" pub "hi.agents.leafcheck" "leaf-to-hub-ok"
wait "$SUB_PID" 2>/dev/null
grep -q "leaf-to-hub-ok" /tmp/leafcheck.out \
  && echo "PASS: leaf-attached AGENTS hi.agents.> propagates to hub" \
  || echo "FAIL: leaf hi.agents.> did NOT reach hub (check per-account remote in leaf.conf)"
```

All five checks must output `PASS` before this runbook is considered complete.
(Check 5 applies only to hosts running a leaf node; skip it on the hub itself.)

---

## Step 6: Rollback

If clients cannot connect after enabling enforcement:

1. Stop NATS.
2. Restore the previous `server.conf` (remove `verify_and_map = true` and the `accounts {}`
   block, or revert to the pre-ADR-010 config from git).
3. Restart NATS.
4. Diagnose cert/SAN issues with `openssl x509 -noout -ext subjectAltName -in <cert>` and
   confirm `accounts {}` `user` values match the DNS SANs exactly.
5. Re-run from Step 1.

```bash
# Quick rollback — revert to pre-auth config
git -C /path/to/Odysseus show HEAD~1:configs/nats/server.conf \
  > /tmp/server.conf.prev
sudo cp /tmp/server.conf.prev /etc/nats/server.conf
sudo systemctl restart nats
```

---

## Appendix: Telemachy Client mTLS Configuration (planned)

> This section covers the **Telemachy client** side of NATS mTLS. The server-side
> `verify_and_map` authentication and subject-scoped `accounts {}` authorization are
> defined in ADR-010 and configured in the steps above.
>
> **Status:** The Telemachy client-cert (mTLS) wiring described below is **not yet
> shipped** in `provisioning/ProjectTelemachy`. It is tracked as the follow-up issue
> "ProjectTelemachy: add NATS client-cert (mTLS) wiring" (see the note in Step 3). The
> symbols referenced here (`telemachy.nats_client.connect_nats()`, the
> `NatsConnectionError` gate, and the `test_client_cert_loaded_for_mtls` test) are the
> **target design** for that issue and do not exist on a released submodule pin yet. This
> appendix documents the intended operator-facing configuration so it is ready when the
> code lands; do not expect `telemachy run` to perform the gate until the follow-up issue
> is merged and the submodule pointer is bumped.

Once the follow-up wiring lands, set the following environment variables so Telemachy
connects over mutual TLS:

| Component | `NATS_URL` | `TLS_CERT_FILE` | `TLS_KEY_FILE` | `TLS_CA_BUNDLE` |
|-----------|------------|-----------------|----------------|-----------------|
| Telemachy | `tls://…`  | role cert PEM   | role key PEM   | CA bundle PEM   |

```bash
export NATS_URL=tls://<nats-host>:4222
export TLS_CERT_FILE=/etc/nats/certs/telemachy-cert.pem
export TLS_KEY_FILE=/etc/nats/certs/telemachy-key.pem
export TLS_CA_BUNDLE=/etc/nats/certs/ca.pem
```

Once implemented, when `NATS_URL=tls://…`, `telemachy run` is intended to perform a
**fail-closed mTLS verification gate** before executing the workflow: it opens a NATS
connection via `telemachy.nats_client.connect_nats()` (passing the client cert as
`tls=`/`tls_hostname=`), then drains it. If the handshake fails (cert rejected, CA
mismatch, server unreachable), `run` aborts with a clear `NatsConnectionError` message and
a non-zero exit — it does not proceed to workflow execution.

This gate is the planned complement to the `require_tls` gate in `agamemnon_client.py` that
rejects plain `nats://` connections when `REQUIRE_TLS=true`.

### CI note (applies once the wiring lands)

When the follow-up wiring ships, CI images that run the Telemachy unit tests must ship the
`openssl` binary. The planned `test_client_cert_loaded_for_mtls` test generates a
self-signed cert at runtime into `tmp_path` via `openssl req -x509 …` and calls
`pytest.skip` if `openssl` is absent.
