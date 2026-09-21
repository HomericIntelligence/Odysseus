#!/usr/bin/env bash
# Negative + positive tests for the config validators (issue #198, TDD).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT" || exit 1

if python3 tests/test_validate_nomad_config.py; then
    pass "repository-bound Nomad validator checks pass"
else
    fail "repository-bound Nomad validator checks failed"
fi

if python3 tests/test_validate_nats_provision.py; then
    pass "content-pinned NATS parser provisioning checks pass"
else
    fail "content-pinned NATS parser provisioning checks failed"
fi

TEST_TMP_PARENT="${TMPDIR:-/tmp}"
TMP=""
if ! TMP="$(mktemp -d "$TEST_TMP_PARENT/odysseus-config-validators.XXXXXX")"; then
    fail_exit "could not allocate the config-validator test directory"
fi
if [[ -z "$TMP" || "$TMP" != /* || ! -d "$TMP" || -L "$TMP" \
    || "${TMP##*/}" != odysseus-config-validators.* ]]; then
    fail_exit "config-validator test directory is not a direct temporary directory"
fi
cleanup() {
    if [[ -n "$TMP" && "$TMP" == /* && -d "$TMP" && ! -L "$TMP" \
        && "${TMP##*/}" == odysseus-config-validators.* ]]; then
        rm -rf -- "$TMP"
    fi
}
trap cleanup EXIT

canonical_inventory="$TMP/canonical-configs.nul"
canonical_configs=()
canonical_inventory_ok=1
if find "$ROOT/configs/nats" -type f -name '*.conf' -print0 >"$canonical_inventory"; then
    while IFS= read -r -d '' canonical_config; do
        canonical_configs+=("$canonical_config")
    done <"$canonical_inventory"
    if [[ "${#canonical_configs[@]}" -eq 0 ]]; then
        fail "canonical NATS config inventory is empty"
        canonical_inventory_ok=0
    fi
else
    fail "canonical NATS config inventory is unavailable"
    canonical_inventory_ok=0
fi

info "validators characterize the protected canonical configs"
NATS_SERVER=""
NATS_SERVER_SHA256=""
NATS_SERVER_RECEIPT=""
parser_dir="$TMP/nats-parser"
if ! mkdir -m 700 "$parser_dir"; then
    fail "could not allocate the content-pinned NATS parser directory"
elif ! NATS_SERVER_RECEIPT="$(python3 - "$parser_dir" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, "scripts")
from validate_nats_config import provision_nats_server

receipt = provision_nats_server(Path(sys.argv[1]))
print(receipt.path)
print(receipt.sha256)
PY
)"; then
    fail "content-pinned nats-server parser provisioning failed"
elif [[ "$NATS_SERVER_RECEIPT" != *$'\n'* ]]; then
    fail "content-pinned nats-server parser omitted its digest receipt"
else
    NATS_SERVER=${NATS_SERVER_RECEIPT%%$'\n'*}
    NATS_SERVER_SHA256=${NATS_SERVER_RECEIPT#*$'\n'}
fi
if [[ -n "$NATS_SERVER" && -n "$NATS_SERVER_SHA256" ]]; then
    default_nats_output="$TMP/default-nats.out"
    if [[ "$canonical_inventory_ok" -ne 1 ]]; then
        fail "NATS validator default inventory cannot be checked"
    elif python3 scripts/validate_nats_config.py --nats-server "$NATS_SERVER" \
        --expected-nats-server-sha256 "$NATS_SERVER_SHA256" \
        >"$default_nats_output" 2>&1; then
        fail "NATS validator hid the protected leaf remote-token defect"
    elif [[ "$(wc -l <"$default_nats_output")" -eq \
            "${#canonical_configs[@]}" ]] \
        && grep -Fqx "OK: $ROOT/configs/nats/server.conf" \
            "$default_nats_output" \
        && grep -Fq \
            "FAILED: $ROOT/configs/nats/leaf.conf -- nats-server rejected config:" \
            "$default_nats_output" \
        && grep -Fq 'unknown field "token"' "$default_nats_output"; then
        pass "NATS parser covers the exact inventory and reports the protected leaf blocker"
    else
        cat "$default_nats_output" >&2
        fail "NATS validator did not report the exact protected canonical state"
    fi
else
    fail "required nats-server parser is unavailable"
fi
if python3 scripts/validate_compose.py >/dev/null; then pass "compose validator accepts docker-compose*.yml"; else fail "compose validator rejected real files"; fi
if python3 -c 'import hcl2' >/dev/null 2>&1; then
    if python3 scripts/validate_nomad_config.py >/dev/null; then
        pass "Nomad validator accepts configs/nomad/*.hcl"
    else
        fail "Nomad validator rejected real configs"
    fi
else
    nomad_dependency_error="$TMP/nomad-dependency-error"
    if python3 scripts/validate_nomad_config.py >"$nomad_dependency_error" 2>&1; then
        fail "Nomad validator passed without its HCL parser dependency"
    elif grep -q 'python-hcl2 is required' "$nomad_dependency_error"; then
        pass "Nomad validator fails closed when its parser dependency is unavailable"
    else
        fail "Nomad validator did not report its missing parser dependency"
    fi
fi

info "validators reject broken fixtures (negative)"

if PYTHON_BIN=python3 "$BASH" tests/test-compose-validation-contract.sh >"$TMP/compose-validation-contract.out" 2>&1; then
    pass "Compose inventory and image-pin contract tests pass"
else
    cat "$TMP/compose-validation-contract.out" >&2
    fail "Compose inventory or image-pin contract tests failed"
fi

missing_parser_output="$TMP/missing-parser.out"
printf 'port = 4222\n' > "$TMP/valid-nats.conf"
if python3 scripts/validate_nats_config.py \
    --nats-server "$TMP/does-not-exist" "$TMP/valid-nats.conf" \
    >"$missing_parser_output" 2>&1; then
    fail "NATS validator passed without its required parser"
elif grep -q 'required nats-server parser' "$missing_parser_output"; then
    pass "NATS validator fails closed when its parser is unavailable"
else
    fail "NATS validator did not report its missing parser dependency"
fi

TRUE_BIN=""
if TRUE_BIN="$(command -v true 2>/dev/null)"; then
    wrong_parser_output="$TMP/wrong-parser.out"
    if python3 scripts/validate_nats_config.py \
        --nats-server "$TRUE_BIN" "$TMP/valid-nats.conf" \
        >"$wrong_parser_output" 2>&1; then
        fail "NATS validator accepted a non-NATS executable as its parser"
    elif grep -q 'not a nats-server executable' "$wrong_parser_output"; then
        pass "NATS validator rejects a non-NATS parser executable"
    else
        fail "NATS validator did not identify the wrong parser executable"
    fi
else
    fail "non-NATS executable fixture is unavailable"
fi

version_only_parser="$TMP/version-only-nats-server"
fixture_shell=$(python3 -c 'from pathlib import Path; print(Path("/bin/sh").resolve(strict=True))')
if ! printf '%s\n' \
    "#!$fixture_shell" \
    'if [ "${1:-}" = "--version" ]; then' \
    '  printf "%s\\n" "nats-server: v2.10.22"' \
    '  exit 0' \
    'fi' \
    'exit 0' >"$version_only_parser"; then
    fail "could not create the version-only parser fixture"
elif ! chmod 700 "$version_only_parser"; then
    fail "could not make the version-only parser fixture executable"
else
    version_only_output="$TMP/version-only-parser.out"
    if python3 scripts/validate_nats_config.py \
        --nats-server "$version_only_parser" "$TMP/valid-nats.conf" \
        >"$version_only_output" 2>&1; then
        fail "NATS validator accepted a parser that only spoofs its version"
    elif grep -q 'malformed semantic canary' "$version_only_output"; then
        pass "NATS validator rejects a version-only parser spoof"
    else
        fail "NATS validator did not report the parser semantic-canary failure"
    fi
fi

rejecting_parser="$TMP/rejecting-nats-server"
if ! printf '%s\n' \
    "#!$fixture_shell" \
    'if [ "${1:-}" = "--version" ]; then' \
    '  printf "%s\\n" "nats-server: v2.10.22"' \
    '  exit 0' \
    'fi' \
    'exit 1' >"$rejecting_parser"; then
    fail "could not create the rejecting parser fixture"
elif ! chmod 700 "$rejecting_parser"; then
    fail "could not make the rejecting parser fixture executable"
else
    rejecting_output="$TMP/rejecting-parser.out"
    if python3 scripts/validate_nats_config.py \
        --nats-server "$rejecting_parser" "$TMP/valid-nats.conf" \
        >"$rejecting_output" 2>&1; then
        fail "NATS validator accepted a parser that rejects valid syntax"
    elif grep -q 'rejected the valid semantic canary' "$rejecting_output"; then
        pass "NATS validator rejects a parser that fails its valid canary"
    else
        fail "NATS validator did not report the valid semantic-canary failure"
    fi
fi

if [[ -n "$NATS_SERVER" ]]; then
    printf 'port = 4222\nthis is not valid\n' > "$TMP/balanced-invalid.conf"
    balanced_output="$TMP/balanced-invalid.out"
    if python3 scripts/validate_nats_config.py \
        --nats-server "$NATS_SERVER" "$TMP/balanced-invalid.conf" \
        >"$balanced_output" 2>&1; then
        fail "NATS validator MISSED balanced invalid syntax"
    elif grep -q 'nats-server rejected' "$balanced_output"; then
        pass "real NATS parser rejects syntax that passes delimiter checks"
    else
        fail "NATS validator did not attribute balanced invalid syntax to the real parser"
    fi

    printf 'authorization = []\n' > "$TMP/malformed-list.conf"
    list_output="$TMP/malformed-list.out"
    if python3 scripts/validate_nats_config.py \
        --nats-server "$NATS_SERVER" "$TMP/malformed-list.conf" \
        >"$list_output" 2>&1; then
        fail "NATS validator MISSED a malformed list value"
    elif grep -q 'nats-server rejected' "$list_output"; then
        pass "real NATS parser rejects malformed list values"
    else
        fail "NATS validator did not attribute the malformed list to the real parser"
    fi

    symlink_config="$TMP/symlink.conf"
    symlink_output="$TMP/symlink.out"
    if ! ln -s "$TMP/valid-nats.conf" "$symlink_config"; then
        fail "could not create the symlink config fixture"
    elif python3 scripts/validate_nats_config.py \
        --nats-server "$NATS_SERVER" "$symlink_config" \
        >"$symlink_output" 2>&1; then
        fail "NATS validator followed a symlink config"
    elif grep -q 'regular non-symlink file' "$symlink_output"; then
        pass "NATS validator rejects symlink configs"
    else
        fail "NATS validator did not report the symlink config boundary"
    fi

    fifo_config="$TMP/fifo.conf"
    if ! mkfifo "$fifo_config"; then
        fail "could not create the FIFO config fixture"
    elif python3 - "$ROOT/scripts/validate_nats_config.py" "$NATS_SERVER" "$fifo_config" <<'PY'
import subprocess
import sys

try:
    completed = subprocess.run(
        [sys.executable, sys.argv[1], "--nats-server", sys.argv[2], sys.argv[3]],
        capture_output=True,
        text=True,
        timeout=3,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(1)
output = completed.stdout + completed.stderr
raise SystemExit(
    0
    if completed.returncode != 0 and "regular non-symlink file" in output
    else 1
)
PY
    then
        pass "NATS validator rejects FIFO configs without blocking"
    else
        fail "NATS validator did not reject the FIFO config within its bound"
    fi

    oversized_config="$TMP/oversized.conf"
    oversized_output="$TMP/oversized.out"
    if ! dd if=/dev/zero of="$oversized_config" bs=1048577 count=1 \
        >/dev/null 2>&1; then
        fail "could not create the oversized config fixture"
    elif python3 scripts/validate_nats_config.py \
        --nats-server "$NATS_SERVER" "$oversized_config" \
        >"$oversized_output" 2>&1; then
        fail "NATS validator accepted an oversized config"
    elif grep -q 'exceeds the 1048576-byte limit' "$oversized_output"; then
        pass "NATS validator bounds config reads"
    else
        fail "NATS validator did not report its config read bound"
    fi
fi

# Broken NATS: unbalanced brace
mkdir -p "$TMP/configs/nats"
printf 'jetstream {\n  store_dir = "/x"\n' > "$TMP/configs/nats/bad.conf"
if python3 - "$TMP/configs/nats/bad.conf" <<'PY'
import sys
sys.path.insert(0, "scripts")
from validate_nats_config import check
ok, _ = check(open(sys.argv[1]).read())
sys.exit(0 if not ok else 1)
PY
then pass "NATS delimiter precheck rejects unbalanced braces"; else fail "NATS delimiter precheck MISSED unbalanced braces"; fi

# Broken compose: services not a mapping
printf 'services: [a, b]\n' > "$TMP/bad-compose.yml"
if python3 - "$TMP/bad-compose.yml" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "scripts")
from validate_compose import check
ok, _ = check(Path(sys.argv[1]))
sys.exit(0 if not ok else 1)
PY
then pass "compose validator rejects non-mapping services"; else fail "compose validator MISSED non-mapping services"; fi

# Broken Nomad HCL: unterminated list expression
printf 'datacenter = ["dc1"\n' > "$TMP/bad-nomad.hcl"
if python3 -c 'import hcl2' >/dev/null 2>&1; then
    if python3 - "$ROOT/scripts/validate_nomad_config.py" \
        "$TMP" "$TMP/bad-nomad.hcl" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("nomad_validator", sys.argv[1])
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
validator.REPOSITORY_ROOT = Path(sys.argv[2])
try:
    validator.validate(Path(sys.argv[3]), validator.load_parser())
except RuntimeError as error:
    raise SystemExit(0 if "invalid Nomad HCL" in str(error) else 1)
raise SystemExit(1)
PY
    then
        pass "Nomad validator rejects malformed HCL"
    else
        fail "Nomad validator MISSED malformed HCL"
    fi
else
    info "python-hcl2 unavailable — malformed-HCL case runs in the locked pixi environment"
fi

summary
exit_code
