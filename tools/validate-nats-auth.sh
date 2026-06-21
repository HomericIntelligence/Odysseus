#!/usr/bin/env bash
# issue #176: canonical NATS configs MUST authenticate. Returns exit 0 only when
# both configs carry auth, exit 1 otherwise — so it distinguishes a fixed config
# from a credential-less one. Strips comments first; tracks brace depth so a
# nested tls{} block does not prematurely end the leafnodes{} block.
set -euo pipefail
LEAF="${1:-configs/nats/leaf.conf}"
SERVER="${2:-configs/nats/server.conf}"
fail=0

# Emit the contents of the first top-level block named <keyword>, comments stripped.
block() {  # block <file> <keyword>
  sed 's/#.*//' "$1" | awk -v kw="$2" '
    inb==0 && $0 ~ "(^|[[:space:]])" kw "[[:space:]]*\\{" { inb=1; d=0 }
    inb==1 {
      print
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); d+=o-c
      if (d<=0) inb=2
    }'
}

# 1) leaf.conf: the remotes/leafnodes block must carry a credential.
if ! block "$LEAF" leafnodes | grep -Eq '\b(credentials|token|user|password|nkey)\b'; then
  echo "FAIL: $LEAF leafnodes/remotes has no credentials/token/user (issue #176)"; fail=1
fi
# 2) server.conf: a top-level client authorization/accounts/operator must exist.
if ! sed 's/#.*//' "$SERVER" | grep -Eq '^\s*(authorization|accounts|operator)\b'; then
  echo "FAIL: $SERVER has no client authorization/accounts/operator (issue #176)"; fail=1
fi
# 3) server.conf: the leafnodes{} listener must carry its OWN authorization/account.
if ! block "$SERVER" leafnodes | grep -Eq '\b(authorization|account)\b'; then
  echo "FAIL: $SERVER leafnodes{} listener has no authorization (issue #176)"; fail=1
fi
# 4) server.conf: the cluster{} listener must carry authorization/account (issue #306).
#    A cluster{} block is optional (single-host needs none); only enforce when present.
_cluster_block="$(block "$SERVER" cluster)"
if [[ -n "$_cluster_block" ]] && ! grep -Eq '\b(authorization|account)\b' <<<"$_cluster_block"; then
  echo "FAIL: $SERVER cluster{} listener has TLS but no authorization (issue #306)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "OK: NATS configs carry authentication"
exit "$fail"
