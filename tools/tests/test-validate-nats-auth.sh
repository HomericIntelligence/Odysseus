#!/usr/bin/env bash
# Regression tests for tools/validate-nats-auth.sh — both directions per check.
# Exit 0 if all pass; exit 1 with failure details otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$HERE/../validate-nats-auth.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Fixtures used in multiple tests
# ---------------------------------------------------------------------------

AUTHED_LEAF="$TMP/authed-leaf.conf"
cat >"$AUTHED_LEAF" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; token = "$NATS_LEAF_TOKEN" }]
}
EOF

UNAUTHED_LEAF="$TMP/unauthed-leaf.conf"
cat >"$UNAUTHED_LEAF" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422" }]
}
EOF

AUTHED_SERVER="$TMP/authed-server.conf"
cat >"$AUTHED_SERVER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { token = "$NATS_LEAF_TOKEN" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
  authorization { token = "$NATS_CLUSTER_TOKEN" }
}
EOF

# Server with client + leaf auth but NO cluster auth (the #306 bug shape).
UNAUTHED_CLUSTER="$TMP/unauthed-cluster.conf"
cat >"$UNAUTHED_CLUSTER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { token = "$NATS_LEAF_TOKEN" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
}
EOF

# Server with NO cluster block (single-host — should pass).
NO_CLUSTER_SERVER="$TMP/no-cluster.conf"
cat >"$NO_CLUSTER_SERVER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { token = "$NATS_LEAF_TOKEN" }
}
EOF

# Brace-depth guard: authorization OUTSIDE cluster{} must not satisfy check 4.
AUTH_OUTSIDE_CLUSTER="$TMP/auth-outside-cluster.conf"
cat >"$AUTH_OUTSIDE_CLUSTER" <<'EOF'
port = 4222
authorization { token = "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { token = "$NATS_LEAF_TOKEN" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
}
EOF

# ---------------------------------------------------------------------------
# Test 1: real repo configs must pass (both leaf and server authed after fix).
# ---------------------------------------------------------------------------
if "$VALIDATE" "$REPO_ROOT/configs/nats/leaf.conf" "$REPO_ROOT/configs/nats/server.conf" >/dev/null 2>&1; then
    pass "real repo configs pass"
else
    fail_case "real repo configs should pass after issue #176 + #306 fixes"
fi

# ---------------------------------------------------------------------------
# Test 2: authed leaf + authed server with cluster auth → pass.
# ---------------------------------------------------------------------------
if "$VALIDATE" "$AUTHED_LEAF" "$AUTHED_SERVER" >/dev/null 2>&1; then
    pass "authed leaf + authed server (with cluster auth) passes"
else
    fail_case "authed fixtures should pass"
fi

# ---------------------------------------------------------------------------
# Test 3: unauthed leaf → fail (check 1, issue #176).
# ---------------------------------------------------------------------------
if ! "$VALIDATE" "$UNAUTHED_LEAF" "$AUTHED_SERVER" >/dev/null 2>&1; then
    pass "unauthed leaf rejected (check 1)"
else
    fail_case "unauthed leaf should fail"
fi

# ---------------------------------------------------------------------------
# Test 4: cluster{} with TLS but no authorization → fail (check 4, issue #306).
# ---------------------------------------------------------------------------
if ! "$VALIDATE" "$AUTHED_LEAF" "$UNAUTHED_CLUSTER" >/dev/null 2>&1; then
    pass "cluster without authorization rejected (check 4)"
else
    fail_case "cluster{} with TLS but no authorization should fail"
fi

# ---------------------------------------------------------------------------
# Test 5: no cluster{} block → pass (single-host is a valid deployment).
# ---------------------------------------------------------------------------
if "$VALIDATE" "$AUTHED_LEAF" "$NO_CLUSTER_SERVER" >/dev/null 2>&1; then
    pass "no cluster{} block passes (single-host)"
else
    fail_case "missing cluster{} should pass as no-op"
fi

# ---------------------------------------------------------------------------
# Test 6: brace-depth guard — authorization OUTSIDE cluster{} must not satisfy
#          check 4. The top-level authorization{} closes at depth 0 (a sibling
#          of cluster{}, not a child); the parser must not be fooled by it.
# ---------------------------------------------------------------------------
if ! "$VALIDATE" "$AUTHED_LEAF" "$AUTH_OUTSIDE_CLUSTER" >/dev/null 2>&1; then
    pass "authorization outside cluster{} does not satisfy check 4 (brace-depth guard)"
else
    fail_case "authorization outside cluster{} must not satisfy cluster check"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$fail" -eq 0 ]]; then
    echo "ALL PASS"
fi
exit "$fail"
