#!/usr/bin/env bash
# Behavior test for the retired cross-host launcher boundary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
REMOTE_CALLS="$TMP/remote-calls"
FIXTURE_ROOT="$TMP/repo"
mkdir -p "$FAKE_BIN" "$FIXTURE_ROOT/e2e"
cp "$ROOT/e2e/start-crosshost.sh" "$FIXTURE_ROOT/e2e/start-crosshost.sh"

for command_name in curl podman ssh sleep tailscale; do
    cat > "$FAKE_BIN/$command_name" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$REMOTE_CALLS"
exit 0
SH
done
chmod +x "$FAKE_BIN"/*

set +e
CROSSHOST_OUTPUT="$(
    REMOTE_CALLS="$REMOTE_CALLS" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
        bash "$FIXTURE_ROOT/e2e/start-crosshost.sh" 2>&1
)"
CROSSHOST_STATUS=$?
set -e

info "retired cross-host launcher stops before every local or remote effect"
if [ "$CROSSHOST_STATUS" -eq 2 ]; then
    pass "launcher returns the explicit unavailable status"
else
    fail "launcher returned $CROSSHOST_STATUS instead of unavailable status 2"
fi
if grep -q 'cross-host launcher is unavailable' <<<"$CROSSHOST_OUTPUT" \
    && grep -q 'operator-approved targets' <<<"$CROSSHOST_OUTPUT"; then
    pass "launcher explains the trust and approval boundary"
else
    fail "launcher did not explain why activation is unavailable"
fi
if [ ! -s "$REMOTE_CALLS" ]; then
    pass "launcher invokes no network, container, wait, or Tailscale command"
else
    fail "launcher invoked a prohibited effect: $(head -1 "$REMOTE_CALLS")"
fi
if [ ! -e "$FIXTURE_ROOT/.env" ]; then
    pass "launcher writes no Compose environment file"
else
    fail "launcher wrote a Compose environment file"
fi

summary
exit_code
