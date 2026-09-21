#!/usr/bin/env bash
# Regression tests for tools/validate-nats-auth.sh — both directions per check.
# Exit 0 if all pass; exit 1 with failure details otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$HERE/../validate-nats-auth.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TEST_TMP_PARENT="${TMPDIR:-/tmp}"
TMP=""
if ! TMP="$(mktemp -d "$TEST_TMP_PARENT/odysseus-nats-auth.XXXXXX")"; then
    echo "FAIL: could not allocate the NATS auth test directory" >&2
    exit 1
fi
if [[ -z "$TMP" || "$TMP" != /* || ! -d "$TMP" || -L "$TMP" \
    || "${TMP##*/}" != odysseus-nats-auth.* ]]; then
    echo "FAIL: NATS auth test directory is not a direct temporary directory" >&2
    exit 1
fi
cleanup() {
    if [[ -n "$TMP" && "$TMP" == /* && -d "$TMP" && ! -L "$TMP" \
        && "${TMP##*/}" == odysseus-nats-auth.* ]]; then
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

fail=0

pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Fixtures used in multiple tests
# ---------------------------------------------------------------------------

AUTHED_LEAF="$TMP/authed-leaf.conf"
cat >"$AUTHED_LEAF" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://leaf:secret@nats:7422" }]
}
EOF

CREDS_LEAF="$TMP/creds-leaf.conf"
cat >"$CREDS_LEAF" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; credentials = "/run/secrets/leaf.creds" }]
}
EOF

CREDS_ALIAS_LEAF="$TMP/creds-alias-leaf.conf"
cat >"$CREDS_ALIAS_LEAF" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; creds = "/run/secrets/leaf.creds" }]
}
EOF

NKEY_LEAF="$TMP/nkey-leaf.conf"
TEST_NKEY_SEED="$(python3 - <<'PY'
import base64
import binascii
import struct

# Deterministic, public test-only NATS user seed. Never use it as a credential.
payload = bytes([0x95, 0x00]) + bytes(range(32))
checksum = binascii.crc_hqx(payload, 0)
print(base64.b32encode(payload + struct.pack("<H", checksum)).decode().rstrip("="))
PY
)"
cat >"$NKEY_LEAF" <<EOF
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; nkey = "$TEST_NKEY_SEED" }]
}
EOF

SEED_ALIAS_LEAF="$TMP/seed-alias-leaf.conf"
cat >"$SEED_ALIAS_LEAF" <<EOF
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; seed = "$TEST_NKEY_SEED" }]
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
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
  authorization { user = "$NATS_CLUSTER_USER"; password =
    "$NATS_CLUSTER_PASSWORD" }
}
EOF

# Server with client + leaf auth but NO cluster auth (the #306 bug shape).
UNAUTHED_CLUSTER="$TMP/unauthed-cluster.conf"
cat >"$UNAUTHED_CLUSTER" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
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
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

# Brace-depth guard: authorization OUTSIDE cluster{} must not satisfy check 4.
AUTH_OUTSIDE_CLUSTER="$TMP/auth-outside-cluster.conf"
cat >"$AUTH_OUTSIDE_CLUSTER" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { cert_file = "/c.pem" }
}
EOF

EMPTY_LEAF_TOKEN="$TMP/empty-leaf-token.conf"
cat >"$EMPTY_LEAF_TOKEN" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; token = "" }]
}
EOF

NESTED_LEAF_DECOY="$TMP/nested-leaf-decoy.conf"
cat >"$NESTED_LEAF_DECOY" <<'EOF'
leafnodes {
  remotes [{
    url = "nats+tls://nats:7422"
    tls { token =
      "not-a-remote-credential" }
  }]
}
EOF

PARTLY_AUTHED_REMOTES="$TMP/partly-authed-remotes.conf"
cat >"$PARTLY_AUTHED_REMOTES" <<'EOF'
leafnodes {
  remotes = [
    { url = "nats+tls://leaf:secret@one:7422" },
    { url = "nats+tls://two:7422" }
  ]
}
EOF

MIXED_REMOTE_LIST="$TMP/mixed-remote-list.conf"
cat >"$MIXED_REMOTE_LIST" <<'EOF'
leafnodes {
  remotes = [
    { url = "nats+tls://leaf:secret@nats:7422" },
    "not-a-remote-map"
  ]
}
EOF

UNSUPPORTED_REMOTE_TOKEN="$TMP/unsupported-remote-token.conf"
cat >"$UNSUPPORTED_REMOTE_TOKEN" <<'EOF'
leafnodes {
  remotes [{ url = "nats+tls://nats:7422"; token =
    "$NATS_LEAF_TOKEN" }]
}
EOF

REMOTE_ALIAS_COLLISION="$TMP/remote-alias-collision.conf"
cat >"$REMOTE_ALIAS_COLLISION" <<'EOF'
leafnodes {
  remotes [{
    url = "nats+tls://nats:7422"
    credentials = "/run/secrets/leaf.creds"
    CREDS = ""
  }]
}
EOF

EMPTY_TOP_AUTH="$TMP/empty-top-auth.conf"
cat >"$EMPTY_TOP_AUTH" <<'EOF'
port = 4222
authorization {}
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

EMPTY_TOP_AUTH_USERS="$TMP/empty-top-auth-users.conf"
cat >"$EMPTY_TOP_AUTH_USERS" <<'EOF'
port = 4222
authorization { users = [{}] }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

MIXED_TOP_AUTH_USERS="$TMP/mixed-top-auth-users.conf"
cat >"$MIXED_TOP_AUTH_USERS" <<'EOF'
port = 4222
authorization {
  users = [
    { user = "client"; password = "secret" },
    "not-a-user-map"
  ]
}
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

EMPTY_ACCOUNTS="$TMP/empty-accounts.conf"
cat >"$EMPTY_ACCOUNTS" <<'EOF'
port = 4222
accounts {}
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

EMPTY_ACCOUNT_USERS="$TMP/empty-account-users.conf"
cat >"$EMPTY_ACCOUNT_USERS" <<'EOF'
port = 4222
accounts { APP { users = [{}] } }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

EMPTY_OPERATOR="$TMP/empty-operator.conf"
cat >"$EMPTY_OPERATOR" <<'EOF'
port = 4222
operator = ""
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

NESTED_TOP_DECOY="$TMP/nested-top-decoy.conf"
cat >"$NESTED_TOP_DECOY" <<'EOF'
port = 4222
metadata { authorization { token =
  "not-client-auth" } }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

EMPTY_LEAF_LISTENER_AUTH="$TMP/empty-leaf-listener-auth.conf"
cat >"$EMPTY_LEAF_LISTENER_AUTH" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes { port = 7422; authorization {} }
EOF

NESTED_LEAF_LISTENER_DECOY="$TMP/nested-leaf-listener-decoy.conf"
cat >"$NESTED_LEAF_LISTENER_DECOY" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  tls { authorization { user = "not-listener-auth"; password = "decoy" } }
}
EOF

EMPTY_CLUSTER_LISTENER_AUTH="$TMP/empty-cluster-listener-auth.conf"
cat >"$EMPTY_CLUSTER_LISTENER_AUTH" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
cluster { listen = "0.0.0.0:6222"; authorization {} }
EOF

NESTED_CLUSTER_DECOY="$TMP/nested-cluster-decoy.conf"
cat >"$NESTED_CLUSTER_DECOY" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
cluster {
  listen = "0.0.0.0:6222"
  tls { authorization { user = "not-cluster-auth"; password = "decoy" } }
}
EOF

ACCOUNTS_SERVER="$TMP/accounts-server.conf"
cat >"$ACCOUNTS_SERVER" <<'EOF'
port = 4222
tls { verify_and_map = true }
accounts {
  APP { users = [{ user = "app.homeric" }] }
}
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

ALIAS_SERVER="$TMP/alias-server.conf"
cat >"$ALIAS_SERVER" <<'EOF'
port = 4222
authorization { username = "client"; pass = "secret" }
leafnodes {
  port = 7422
  authorization { username = "leaf"; pass = "secret" }
}
cluster {
  listen = "0.0.0.0:6222"
  authorization { username = "route"; pass = "secret" }
}
EOF

CASE_SERVER="$TMP/case-server.conf"
cat >"$CASE_SERVER" <<'EOF'
port = 4222
AUTHORIZATION { USER = "client"; PASSWORD = "secret" }
LEAFNODES {
  port = 7422
  AUTHORIZATION { USER = "leaf"; PASSWORD = "secret" }
}
EOF

NO_AUTH_USER_SERVER="$TMP/no-auth-user-server.conf"
cat >"$NO_AUTH_USER_SERVER" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
no_auth_user = "guest"
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

SYSTEM_ONLY_SERVER="$TMP/system-only-server.conf"
cat >"$SYSTEM_ONLY_SERVER" <<'EOF'
port = 4222
tls { verify_and_map = true }
accounts { SYS { users = [{ user = "sys.homeric" }] } }
system_account = SYS
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

ACCOUNT_ONLY_LISTENER="$TMP/account-only-listener.conf"
cat >"$ACCOUNT_ONLY_LISTENER" <<'EOF'
port = 4222
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes { port = 7422; account = "APP" }
EOF

INCLUDE_SERVER="$TMP/include-server.conf"
cat >"$INCLUDE_SERVER" <<'EOF'
port = 4222
include "uninspected-auth.conf"
authorization { token =
    "$NATS_CLIENT_TOKEN" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

LOCAL_EMPTY_AUTH_VAR_SERVER="$TMP/local-empty-auth-var-server.conf"
cat >"$LOCAL_EMPTY_AUTH_VAR_SERVER" <<'EOF'
EMPTY = ""
port = 4222
authorization { token = $EMPTY }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

UNKNOWN_AUTH_VAR_SERVER="$TMP/unknown-auth-var-server.conf"
cat >"$UNKNOWN_AUTH_VAR_SERVER" <<'EOF'
port = 4222
authorization { token = $UNKNOWN_TOKEN }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

USER_ALIAS_COLLISION_SERVER="$TMP/user-alias-collision-server.conf"
cat >"$USER_ALIAS_COLLISION_SERVER" <<'EOF'
port = 4222
authorization { user = "protected"; USERNAME = ""; password = "secret" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

PASSWORD_ALIAS_COLLISION_SERVER="$TMP/password-alias-collision-server.conf"
cat >"$PASSWORD_ALIAS_COLLISION_SERVER" <<'EOF'
port = 4222
authorization { user = "protected"; password = "secret"; pass = "" }
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

REPEATED_AUTH_SERVER="$TMP/repeated-auth-server.conf"
cat >"$REPEATED_AUTH_SERVER" <<'EOF'
port = 4222
authorization { token = "protected" }
authorization {}
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

REPEATED_LEAF_SERVER="$TMP/repeated-leaf-server.conf"
cat >"$REPEATED_LEAF_SERVER" <<'EOF'
port = 4222
authorization { token = "protected" }
leafnodes {
  port = 7422
  authorization { user = "leaf"; password = "secret" }
}
leafnodes { port = 7423 }
EOF

REPEATED_CLUSTER_SERVER="$TMP/repeated-cluster-server.conf"
cat >"$REPEATED_CLUSTER_SERVER" <<'EOF'
port = 4222
authorization { token = "protected" }
leafnodes { port = 7422; authorization { user = "leaf"; password = "secret" } }
cluster { listen = "0.0.0.0:6222"; authorization { user = "route"; password = "secret" } }
cluster { listen = "0.0.0.0:6223" }
EOF

REPEATED_ACCOUNTS_SERVER="$TMP/repeated-accounts-server.conf"
cat >"$REPEATED_ACCOUNTS_SERVER" <<'EOF'
port = 4222
tls { verify_and_map = true }
accounts { APP { users = [{ user = "app.homeric" }] } }
accounts {}
leafnodes { port = 7422; authorization { user = "leaf"; password = "secret" } }
EOF

REPEATED_OPERATOR_SERVER="$TMP/repeated-operator-server.conf"
cat >"$REPEATED_OPERATOR_SERVER" <<'EOF'
port = 4222
operator = "/run/secrets/operator.jwt"
operator = ""
leafnodes { port = 7422; authorization { user = "leaf"; password = "secret" } }
EOF

OPERATOR_SERVER="$TMP/operator-server.conf"
cat >"$OPERATOR_SERVER" <<'EOF'
port = 4222
operator = "/run/secrets/operator.jwt"
leafnodes {
  port = 7422
  authorization { user = "$NATS_LEAF_USER"; password =
    "$NATS_LEAF_PASSWORD" }
}
EOF

# ---------------------------------------------------------------------------
# Test 1: canonical configurations must declare supported authentication.
# Unsupported remote tokens remain covered independently below.
# ---------------------------------------------------------------------------
canonical_output="$TMP/canonical.out"
if "$VALIDATE" "$REPO_ROOT/configs/nats/leaf.conf" "$REPO_ROOT/configs/nats/server.conf" >"$canonical_output" 2>&1; then
    pass "canonical configurations declare supported authentication"
else
    cat "$canonical_output" >&2
    fail_case "canonical configurations have invalid authentication"
fi

# ---------------------------------------------------------------------------
# Test 2: authed leaf + authed server with cluster auth → pass.
# ---------------------------------------------------------------------------
if "$VALIDATE" "$CREDS_LEAF" "$AUTHED_SERVER" >/dev/null 2>&1; then
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
if ! "$VALIDATE" "$CREDS_LEAF" "$UNAUTHED_CLUSTER" >/dev/null 2>&1; then
    pass "cluster without authorization rejected (check 4)"
else
    fail_case "cluster{} with TLS but no authorization should fail"
fi

# ---------------------------------------------------------------------------
# Test 5: no cluster{} block → pass (single-host is a valid deployment).
# ---------------------------------------------------------------------------
if "$VALIDATE" "$CREDS_LEAF" "$NO_CLUSTER_SERVER" >/dev/null 2>&1; then
    pass "no cluster{} block passes (single-host)"
else
    fail_case "missing cluster{} should pass as no-op"
fi

# ---------------------------------------------------------------------------
# Test 6: brace-depth guard — authorization OUTSIDE cluster{} must not satisfy
#          check 4. The top-level authorization{} closes at depth 0 (a sibling
#          of cluster{}, not a child); the parser must not be fooled by it.
# ---------------------------------------------------------------------------
if ! "$VALIDATE" "$CREDS_LEAF" "$AUTH_OUTSIDE_CLUSTER" >/dev/null 2>&1; then
    pass "authorization outside cluster{} does not satisfy check 4 (brace-depth guard)"
else
    fail_case "authorization outside cluster{} must not satisfy cluster check"
fi

# ---------------------------------------------------------------------------
# Empty values, partial remote coverage, and nested lexical decoys must fail.
# ---------------------------------------------------------------------------
for rejected_leaf in \
    "$EMPTY_LEAF_TOKEN" \
    "$NESTED_LEAF_DECOY" \
    "$PARTLY_AUTHED_REMOTES" \
    "$MIXED_REMOTE_LIST" \
    "$UNSUPPORTED_REMOTE_TOKEN" \
    "$REMOTE_ALIAS_COLLISION"; do
    if ! "$VALIDATE" "$rejected_leaf" "$AUTHED_SERVER" >/dev/null 2>&1; then
        pass "$(basename "$rejected_leaf") is rejected"
    else
        fail_case "$(basename "$rejected_leaf") must not satisfy leaf remote authentication"
    fi
done

for rejected_server in \
    "$EMPTY_TOP_AUTH" \
    "$EMPTY_TOP_AUTH_USERS" \
    "$MIXED_TOP_AUTH_USERS" \
    "$EMPTY_ACCOUNTS" \
    "$EMPTY_ACCOUNT_USERS" \
    "$EMPTY_OPERATOR" \
    "$NESTED_TOP_DECOY" \
    "$EMPTY_LEAF_LISTENER_AUTH" \
    "$NESTED_LEAF_LISTENER_DECOY" \
    "$EMPTY_CLUSTER_LISTENER_AUTH" \
    "$NESTED_CLUSTER_DECOY" \
    "$NO_AUTH_USER_SERVER" \
    "$SYSTEM_ONLY_SERVER" \
    "$ACCOUNT_ONLY_LISTENER" \
    "$INCLUDE_SERVER" \
    "$LOCAL_EMPTY_AUTH_VAR_SERVER" \
    "$UNKNOWN_AUTH_VAR_SERVER" \
    "$USER_ALIAS_COLLISION_SERVER" \
    "$PASSWORD_ALIAS_COLLISION_SERVER" \
    "$REPEATED_AUTH_SERVER" \
    "$REPEATED_LEAF_SERVER" \
    "$REPEATED_CLUSTER_SERVER" \
    "$REPEATED_ACCOUNTS_SERVER" \
    "$REPEATED_OPERATOR_SERVER"; do
    if ! "$VALIDATE" "$CREDS_LEAF" "$rejected_server" >/dev/null 2>&1; then
        pass "$(basename "$rejected_server") is rejected"
    else
        fail_case "$(basename "$rejected_server") must not satisfy server authentication"
    fi
done

# ---------------------------------------------------------------------------
# Non-empty authorization, accounts, and operator client-auth forms pass.
# ---------------------------------------------------------------------------
for accepted_server in \
    "$AUTHED_SERVER" \
    "$ACCOUNTS_SERVER" \
    "$OPERATOR_SERVER" \
    "$ALIAS_SERVER" \
    "$CASE_SERVER"; do
    if "$VALIDATE" "$CREDS_LEAF" "$accepted_server" >/dev/null 2>&1; then
        pass "$(basename "$accepted_server") has valid client and listener authentication declarations"
    else
        fail_case "$(basename "$accepted_server") should pass"
    fi
done

for accepted_leaf in \
    "$AUTHED_LEAF" \
    "$CREDS_LEAF" \
    "$CREDS_ALIAS_LEAF" \
    "$NKEY_LEAF" \
    "$SEED_ALIAS_LEAF"; do
    if "$VALIDATE" "$accepted_leaf" "$AUTHED_SERVER" >/dev/null 2>&1; then
        pass "$(basename "$accepted_leaf") uses a pinned supported remote credential form"
    else
        fail_case "$(basename "$accepted_leaf") should pass"
    fi
done

# ---------------------------------------------------------------------------
# Real-parser parity. These field/alias fixtures are pinned to the NATS
# v2.10.22 grammar used by CI. This pinned lane always provisions that exact
# artifact; compatibility checks for newer releases belong in a separate lane.
# ---------------------------------------------------------------------------
NATS_SERVER=""
NATS_SERVER_SHA256=""
NATS_SERVER_RECEIPT=""
parser_dir="$TMP/nats-parser"
if ! mkdir -m 700 "$parser_dir"; then
    fail_case "could not allocate the content-pinned NATS parser directory"
elif ! NATS_SERVER_RECEIPT="$(python3 - "$parser_dir" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path(sys.argv[2]) / "scripts"))
from validate_nats_config import provision_nats_server

receipt = provision_nats_server(Path(sys.argv[1]))
print(receipt.path)
print(receipt.sha256)
PY
)"; then
    fail_case "content-pinned nats-server provisioning failed for auth parity"
elif [[ "$NATS_SERVER_RECEIPT" != *$'\n'* ]]; then
    fail_case "content-pinned nats-server provisioning omitted its digest receipt"
else
    NATS_SERVER=${NATS_SERVER_RECEIPT%%$'\n'*}
    NATS_SERVER_SHA256=${NATS_SERVER_RECEIPT#*$'\n'}
fi

run_pinned_parser() {
    python3 "$REPO_ROOT/scripts/validate_nats_config.py" \
        --nats-server "$NATS_SERVER" \
        --expected-nats-server-sha256 "$NATS_SERVER_SHA256" \
        "$1"
}

if [[ -n "$NATS_SERVER" && -n "$NATS_SERVER_SHA256" ]]; then
    parser_swap_sentinel="$TMP/post-handoff-parser-ran"
    parser_swap_output="$TMP/post-handoff-parser.out"
    mv "$NATS_SERVER" "$NATS_SERVER.selected"
    cat >"$NATS_SERVER" <<EOF
#!/bin/sh
printf '%s\n' hostile > "$parser_swap_sentinel"
exit 0
EOF
    chmod 700 "$NATS_SERVER"
    if run_pinned_parser "$AUTHED_LEAF" >"$parser_swap_output" 2>&1; then
        fail_case "digest receipt accepted a post-handoff parser replacement"
    elif [[ -e "$parser_swap_sentinel" ]]; then
        fail_case "post-handoff parser replacement executed hostile bytes"
    elif grep -q 'SHA-256' "$parser_swap_output"; then
        pass "digest receipt rejects a post-handoff parser replacement"
    else
        cat "$parser_swap_output" >&2
        fail_case "post-handoff parser replacement failed without a digest diagnostic"
    fi
    rm -f -- "$NATS_SERVER"
    mv "$NATS_SERVER.selected" "$NATS_SERVER"

    parser_platform=$(python3 -c \
        'import sys; print("linux" if sys.platform.startswith("linux") else "other")')
    if [[ "$parser_platform" == linux ]]; then
        for parser_accepted in \
            "$AUTHED_LEAF" \
            "$CREDS_LEAF" \
            "$CREDS_ALIAS_LEAF" \
            "$NKEY_LEAF" \
            "$SEED_ALIAS_LEAF" \
            "$ALIAS_SERVER" \
            "$CASE_SERVER"; do
            if NATS_CLIENT_TOKEN=client NATS_LEAF_USER=leaf NATS_LEAF_PASSWORD=secret \
                NATS_CLUSTER_USER=route NATS_CLUSTER_PASSWORD=secret \
                run_pinned_parser "$parser_accepted" >/dev/null 2>&1; then
                pass "$(basename "$parser_accepted") matches pinned NATS 2.10.22 grammar"
            else
                fail_case "$(basename "$parser_accepted") diverges from maintained NATS grammar"
            fi
        done

        parser_token_output="$TMP/parser-token.out"
        if run_pinned_parser "$UNSUPPORTED_REMOTE_TOKEN" \
            >"$parser_token_output" 2>&1; then
            fail_case "pinned NATS 2.10.22 parser accepted the unsupported remote token"
        elif grep -q 'unknown field.*token' "$parser_token_output"; then
            pass "pinned NATS 2.10.22 parser rejects the unsupported remote token"
        else
            cat "$parser_token_output" >&2
            fail_case "pinned NATS 2.10.22 parser rejected remote token for an unexpected reason"
        fi
    else
        parser_platform_output="$TMP/parser-platform.out"
        if run_pinned_parser "$AUTHED_LEAF" \
            >"$parser_platform_output" 2>&1; then
            fail_case "non-Linux host executed the pinned NATS parser"
        elif grep -q 'Linux descriptor execution is required' \
            "$parser_platform_output"; then
            pass "non-Linux pinned-parser execution fails closed"
        else
            cat "$parser_platform_output" >&2
            fail_case "non-Linux pinned-parser failure lacked its platform diagnostic"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$fail" -eq 0 ]]; then
    echo "ALL PASS"
fi
exit "$fail"
