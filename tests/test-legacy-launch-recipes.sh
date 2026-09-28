#!/usr/bin/env bash
# Behavior tests for the explicit legacy-runtime service identity boundary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
JUST_BIN="$(command -v just)"
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-legacy-launch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
MARKER="$TMP/python.invocation"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/python3" <<'SH'
#!/bin/sh
set -eu
{
    printf 'uid=%s\n' "${HOMERIC_LEGACY_SERVICE_UID-<unset>}"
    printf 'nats=%s\n' "${NATS_URL-<unset>}"
    printf 'dry_run=%s\n' "${DRY_RUN-<unset>}"
    printf 'no_github=%s\n' "${NO_GITHUB-<unset>}"
    printf 'args=%s\n' "$*"
} > "${ODYSSEUS_TEST_PYTHON_MARKER:?}"
SH
chmod +x "$FAKE_BIN/python3"

run_recipe() {
    local recipe="$1" nats_url="$2"
    PATH="$FAKE_BIN:/usr/bin:/bin" \
        ODYSSEUS_TEST_PYTHON_MARKER="$MARKER" \
        "$JUST_BIN" --justfile "$ROOT/justfile" --working-directory "$ROOT" \
        "$recipe" "$nats_url"
}

recipe_output_contains() {
    local recipe=$1 expected=$2
    grep -Fq "$expected" "$TMP/$recipe.out" || \
        grep -Fq "$expected" "$TMP/$recipe.err"
}

info "live legacy launchers require an explicit service UID before Python"
for recipe in start-claude-myrmidon start-claude-myrmidon-multi; do
    rm -f "$MARKER"
    if (unset HOMERIC_LEGACY_SERVICE_UID; run_recipe "$recipe" \
        'tls://fixture.invalid:4222') \
        > "$TMP/$recipe.out" 2> "$TMP/$recipe.err"; then
        fail "$recipe accepted an absent service UID"
    elif [ -e "$MARKER" ]; then
        fail "$recipe invoked Python before rejecting an absent service UID"
    elif recipe_output_contains "$recipe" \
        'set HOMERIC_LEGACY_SERVICE_UID to the effective decimal service UID'; then
        pass "$recipe rejects an absent service UID before Python"
    else
        sed 's/^/    /' "$TMP/$recipe.out" >&2
        sed 's/^/    /' "$TMP/$recipe.err" >&2
        fail "$recipe failed outside the explicit service UID boundary"
    fi
done

info "live launchers transport the exact UID and quoted NATS URL"
service_uid="$(id -u)"
nats_url='tls://fixture.invalid:4222?name=legacy worker'
for recipe in start-claude-myrmidon start-claude-myrmidon-multi; do
    rm -f "$MARKER"
    if HOMERIC_LEGACY_SERVICE_UID="$service_uid" \
        run_recipe "$recipe" "$nats_url" \
            > "$TMP/$recipe-live.out" 2> "$TMP/$recipe-live.err" && \
        grep -Fqx "uid=$service_uid" "$MARKER" && \
        grep -Fqx "nats=$nats_url" "$MARKER" && \
        grep -Fqx 'dry_run=<unset>' "$MARKER" && \
        grep -Fqx 'no_github=<unset>' "$MARKER"; then
        pass "$recipe preserves its explicit runtime identity and transport"
    else
        [ ! -e "$MARKER" ] || sed 's/^/    /' "$MARKER" >&2
        sed 's/^/    /' "$TMP/$recipe-live.out" >&2
        sed 's/^/    /' "$TMP/$recipe-live.err" >&2
        fail "$recipe changed or omitted its explicit launch inputs"
    fi
done

info "dry runs remain identity-free and carry no-GitHub controls"
for recipe in e2e-dry-run e2e-multi-dry-run; do
    rm -f "$MARKER"
    if (unset HOMERIC_LEGACY_SERVICE_UID; run_recipe "$recipe" "$nats_url") \
        > "$TMP/$recipe.out" 2> "$TMP/$recipe.err" && \
        grep -Fqx 'uid=<unset>' "$MARKER" && \
        grep -Fqx "nats=$nats_url" "$MARKER" && \
        grep -Fqx 'dry_run=1' "$MARKER" && \
        grep -Fqx 'no_github=1' "$MARKER"; then
        pass "$recipe stays identity-free and side-effect disabled"
    else
        [ ! -e "$MARKER" ] || sed 's/^/    /' "$MARKER" >&2
        sed 's/^/    /' "$TMP/$recipe.out" >&2
        sed 's/^/    /' "$TMP/$recipe.err" >&2
        fail "$recipe did not preserve its dry-run boundary"
    fi
done

summary
exit_code
