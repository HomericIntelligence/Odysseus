#!/usr/bin/env bash
# Regression tests for tools/validate-nats-auth.sh — both pass and fail directions.
# Exit 0 if all pass; exit 1 with failure details otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$HERE/../validate-nats-auth.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Fully authenticated leaf.conf (URL-embedded user/password)
AUTHED_LEAF="$TMP/authed-leaf.conf"
cat >"$AUTHED_LEAF" <<'EOF'
leafnodes {
  remotes = [{ url = "nats+tls://user:pass@127.0.0.1:7422" }]
}
EOF

# leaf.conf using a credentials file (also valid)
CREDS_LEAF="$TMP/creds-leaf.conf"
cat >"$CREDS_LEAF" <<'EOF'
leafnodes {
  remotes = [{ url = "nats+tls://127.0.0.1:7422"; credentials = "/etc/nats/certs/leaf.creds" }]
}
EOF

# Unauthenticated leaf.conf (no credentials, no URL auth)
UNAUTHED_LEAF="$TMP/unauthed-leaf.conf"
cat >"$UNAUTHED_LEAF" <<'EOF'
leafnodes {
  remotes = [{ url = "nats+tls://127.0.0.1:7422" }]
}
EOF

# Fully authenticated server.conf (client token + leafnodes user/pass + cluster user/pass)
AUTHED_SERVER="$TMP/authed-server.conf"
cat >"$AUTHED_SERVER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password = "$NATS_LEAF_PASSWORD" }
}
cluster {
  name = "test"
  listen = "0.0.0.0:6222"
  authorization { user = "$NATS_CLUSTER_USER"; password = "$NATS_CLUSTER_PASSWORD" }
}
EOF

# Server with no authorization blocks at all (check 2 catches this — no
# top-level authorization/accounts/operator keyword anywhere in the file)
NO_CLIENT_AUTH_SERVER="$TMP/no-client-auth-server.conf"
cat >"$NO_CLIENT_AUTH_SERVER" <<'EOF'
port = 4222
leafnodes {
  port = 7422
}
cluster {
  name = "test"
  listen = "0.0.0.0:6222"
}
EOF

# Server with client + leaf auth but NO cluster authorization (the #318 bug shape)
NO_CLUSTER_AUTH_SERVER="$TMP/no-cluster-auth-server.conf"
cat >"$NO_CLUSTER_AUTH_SERVER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "u"; password = "p" }
}
cluster {
  name = "test"
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
}
EOF

# Server with client + cluster auth but NO leafnodes authorization
NO_LEAF_AUTH_SERVER="$TMP/no-leaf-auth-server.conf"
cat >"$NO_LEAF_AUTH_SERVER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  tls { cert_file = "/c.pem" }
}
cluster {
  name = "test"
  listen = "0.0.0.0:6222"
  authorization { user = "u"; password = "p" }
}
EOF

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Canonical repo configs must pass
if bash "$VALIDATE" 2>/dev/null; then
  pass "real repo configs pass"
else
  fail_case "real repo configs rejected by validator"
fi

# Authed leaf + authed server (with cluster auth) — must pass
if bash "$VALIDATE" "$AUTHED_LEAF" "$AUTHED_SERVER" 2>/dev/null; then
  pass "authed leaf + authed server (with cluster auth) passes"
else
  fail_case "authed leaf + authed server was rejected"
fi

# Credentials-file leaf + authed server — must pass
if bash "$VALIDATE" "$CREDS_LEAF" "$AUTHED_SERVER" 2>/dev/null; then
  pass "credentials-file leaf + authed server passes"
else
  fail_case "credentials-file leaf + authed server was rejected"
fi

# Unauthenticated leaf — must fail (check 1)
if ! bash "$VALIDATE" "$UNAUTHED_LEAF" "$AUTHED_SERVER" 2>/dev/null; then
  pass "unauthed leaf rejected (check 1)"
else
  fail_case "unauthed leaf was NOT rejected — check 1 broken"
fi

# Server missing client auth — must fail (check 2)
if ! bash "$VALIDATE" "$AUTHED_LEAF" "$NO_CLIENT_AUTH_SERVER" 2>/dev/null; then
  pass "server without client authorization rejected (check 2)"
else
  fail_case "server without client auth was NOT rejected — check 2 broken"
fi

# Server missing leafnodes auth — must fail (check 3)
if ! bash "$VALIDATE" "$AUTHED_LEAF" "$NO_LEAF_AUTH_SERVER" 2>/dev/null; then
  pass "server without leafnodes authorization rejected (check 3)"
else
  fail_case "server without leafnodes auth was NOT rejected — check 3 broken"
fi

# Server without cluster authorization — must fail (check 4, issue #318)
if ! bash "$VALIDATE" "$AUTHED_LEAF" "$NO_CLUSTER_AUTH_SERVER" 2>/dev/null; then
  pass "cluster without authorization rejected (check 4)"
else
  fail_case "server without cluster auth was NOT rejected — check 4 broken (issue #318)"
fi

exit "$fail"
