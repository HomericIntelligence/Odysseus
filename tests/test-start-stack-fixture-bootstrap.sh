#!/usr/bin/env bash
# Failure-path test for the start-stack health fixture bootstrap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

if ! fixture_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)" \
    || [ -z "$fixture_parent" ]; then
    printf '%s\n' 'ERROR: could not resolve bootstrap fixture parent' >&2
    exit 1
fi
fixture_prefix="$fixture_parent/odysseus-start-stack-bootstrap."
fixture_root=""
if ! fixture_root="$(mktemp -d "${fixture_prefix}XXXXXX")" \
    || [ -z "$fixture_root" ] || [ ! -d "$fixture_root" ] \
    || [ -L "$fixture_root" ]; then
    printf '%s\n' 'ERROR: could not create start-stack bootstrap fixture' >&2
    exit 1
fi

cleanup_fixture() {
    local suffix
    suffix="${fixture_root#"$fixture_prefix"}"
    if [ -z "$fixture_root" ] || [ "$suffix" = "$fixture_root" ] \
        || [ -z "$suffix" ] || [ ! -d "$fixture_root" ] \
        || [ -L "$fixture_root" ]; then
        printf 'ERROR: refusing unsafe bootstrap fixture cleanup: %s\n' \
            "$fixture_root" >&2
        return
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*)
            printf 'ERROR: refusing unsafe bootstrap fixture cleanup: %s\n' \
                "$fixture_root" >&2
            return
            ;;
    esac
    rm -r -- "$fixture_root"
}
trap cleanup_fixture EXIT

fake_bin="$fixture_root/bin"
mkdir "$fake_bin"
mkdir_marker="$fixture_root/mkdir-called"
failure_path="$fixture_root/odysseus-start-stack-health.Failed73"
mkdir "$failure_path"
printf '%s\n' 'keep-existing-fixture' > "$failure_path/sentinel"

cat > "$fake_bin/mktemp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${ODYSSEUS_TEST_MKTEMP_OUTPUT:?}"
exit 73
SH

cat > "$fake_bin/mkdir" <<'SH'
#!/usr/bin/env bash
: > "${ODYSSEUS_TEST_MKDIR_MARKER:?}"
kill -TERM "$PPID"
exit 99
SH
chmod +x "$fake_bin/mktemp" "$fake_bin/mkdir"

set +e
output="$(
    ODYSSEUS_TEST_MKTEMP_OUTPUT="$failure_path" \
    ODYSSEUS_TEST_MKDIR_MARKER="$mkdir_marker" \
    TMPDIR="$fixture_root" \
    PATH="$fake_bin:/usr/bin:/bin" \
        /bin/bash "$ROOT/tests/test-start-stack-health.sh" 2>&1
)"
status=$?
set -e

if [ "$status" -ne 0 ] \
    && [ ! -e "$mkdir_marker" ] \
    && [ -d "$failure_path" ] \
    && [ "$(cat "$failure_path/sentinel")" = keep-existing-fixture ] \
    && grep -Fq 'could not create start-stack health fixture' <<<"$output"; then
    printf '%s\n' 'PASS: fixture creation failure stops before side effects'
    exit 0
fi

printf '%s\n' 'FAIL: fixture creation failure reached a later side effect' >&2
printf 'status=%s\n%s\n' "$status" "$output" >&2
exit 1
