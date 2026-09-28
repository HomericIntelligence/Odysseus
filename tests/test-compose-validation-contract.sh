#!/usr/bin/env bash
# Behavior tests for the Compose inventory and image-pin validators.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

run_pin_check() {
    "$ROOT/scripts/check_e2e_image_pins.sh" "$1" >"$2" 2>&1
}

printf 'services:\n  app:\n    image: example/app:1@sha256:%064d\n' 0 \
    >"$TMP/pinned.yml"
if run_pin_check "$TMP/pinned.yml" "$TMP/pinned.out"; then
    pass "the image-pin check accepts a manifest whose images use digests"
else
    fail "the image-pin check rejected a digest-pinned manifest"
fi

printf 'services:\n  app:\n    image: example/app:latest\n' >"$TMP/unpinned.yml"
if run_pin_check "$TMP/unpinned.yml" "$TMP/unpinned.out"; then
    fail "the image-pin check accepted an unpinned image"
elif grep -Fq 'unpinned' "$TMP/unpinned.out"; then
    pass "the image-pin check rejects an unpinned image"
else
    fail "the image-pin check omitted the unpinned-image diagnostic"
fi

printf 'services:\n  app:\n    build: .\n' >"$TMP/no-images.yml"
if run_pin_check "$TMP/no-images.yml" "$TMP/no-images.out"; then
    fail "the image-pin check accepted a manifest with no image declarations"
elif grep -Fq 'no image' "$TMP/no-images.out"; then
    pass "the image-pin check rejects a manifest with no image declarations"
else
    fail "the image-pin check omitted the empty-image-inventory diagnostic"
fi

printf 'services:\n  app:\n    image: example/app:latest # @sha256:%064d\n' 0 \
    >"$TMP/comment-decoy.yml"
if run_pin_check "$TMP/comment-decoy.yml" "$TMP/comment-decoy.out"; then
    fail "the image-pin check accepted a digest found only in a YAML comment"
elif grep -Fq 'unpinned' "$TMP/comment-decoy.out"; then
    pass "the image-pin check ignores digest-shaped comment decoys"
else
    fail "the image-pin check omitted the comment-decoy diagnostic"
fi

printf 'services:\n  decoy:\n    image: example/decoy:1@sha256:%064d\n  app:\n    "image": example/app:latest\n' 0 \
    >"$TMP/quoted-key.yml"
if run_pin_check "$TMP/quoted-key.yml" "$TMP/quoted-key.out"; then
    fail "the image-pin check ignored an unpinned quoted image key"
elif grep -Fq 'example/app:latest' "$TMP/quoted-key.out"; then
    pass "the image-pin check evaluates quoted YAML image keys"
else
    fail "the image-pin check omitted the quoted-key diagnostic"
fi

printf 'services:\n  app: [\n' >"$TMP/malformed.yml"
if run_pin_check "$TMP/malformed.yml" "$TMP/malformed.out"; then
    fail "the image-pin check accepted malformed YAML"
elif grep -Eqi 'yaml|parse|invalid' "$TMP/malformed.out"; then
    pass "the image-pin check fails closed when YAML parsing fails"
else
    fail "the image-pin check omitted its YAML parse diagnostic"
fi

ln -s "$TMP/pinned.yml" "$TMP/pinned-link.yml"
if run_pin_check "$TMP/pinned-link.yml" "$TMP/pinned-link.out"; then
    fail "the image-pin check followed a Compose symlink"
elif grep -Eqi 'symlink|regular|safely open|too many levels' \
    "$TMP/pinned-link.out"; then
    pass "the image-pin check rejects Compose symlinks"
else
    fail "the image-pin check omitted its symlink diagnostic"
fi

cp "$TMP/pinned.yml" "$TMP/pinned-hardlink-source.yml"
ln "$TMP/pinned-hardlink-source.yml" "$TMP/pinned-hardlink.yml"
if run_pin_check "$TMP/pinned-hardlink.yml" "$TMP/pinned-hardlink.out"; then
    fail "the image-pin check accepted a multiply linked Compose file"
elif grep -Eqi 'single|link|regular|safely open' \
    "$TMP/pinned-hardlink.out"; then
    pass "the image-pin check requires singly linked Compose files"
else
    fail "the image-pin check omitted its hard-link diagnostic"
fi

"$PYTHON_BIN" - "$TMP/pinned-oversized.yml" <<'PY'
from pathlib import Path
import sys

limit = 1_048_576
path = Path(sys.argv[1])
prefix = (
    b"services:\n  app:\n"
    b"    image: example/app:1@sha256:" + b"0" * 64 + b"\n#"
)
path.write_bytes(prefix + b"x" * (limit + 1 - len(prefix)))
PY
if run_pin_check "$TMP/pinned-oversized.yml" "$TMP/pinned-oversized.out"; then
    fail "the image-pin check accepted a Compose file above its byte limit"
elif grep -Fq '1048576-byte limit' "$TMP/pinned-oversized.out"; then
    pass "the image-pin check enforces the shared Compose byte limit"
else
    fail "the image-pin check omitted its byte-limit diagnostic"
fi

{
    printf 'defaults: &defaults {image: example/app:1@sha256:%064d}\n' 0
    printf 'services:\n'
    for index in $(seq 1 101); do
        printf '  app%s: *defaults\n' "$index"
    done
} >"$TMP/pinned-alias-poison.yml"
if run_pin_check "$TMP/pinned-alias-poison.yml" \
    "$TMP/pinned-alias-poison.out"; then
    fail "the image-pin check accepted an alias-expansion poison document"
elif grep -Fq 'alias limit' "$TMP/pinned-alias-poison.out"; then
    pass "the image-pin check enforces the shared YAML alias limit"
else
    fail "the image-pin check omitted its YAML alias-limit diagnostic"
fi

"$PYTHON_BIN" - "$TMP/pinned-depth-poison.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(
    "services:\n  app:\n"
    "    image: example/app:1@sha256:" + "0" * 64 + "\n"
    "metadata: " + "[" * 51 + "0" + "]" * 51 + "\n",
    encoding="utf-8",
)
PY
if run_pin_check "$TMP/pinned-depth-poison.yml" \
    "$TMP/pinned-depth-poison.out"; then
    fail "the image-pin check accepted an over-deep YAML document"
elif grep -Fq 'depth limit' "$TMP/pinned-depth-poison.out"; then
    pass "the image-pin check enforces the shared YAML depth limit"
else
    fail "the image-pin check omitted its YAML depth-limit diagnostic"
fi

new_validator_root() {
    FIXTURE_ROOT="$TMP/$1"
    mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/e2e"
    cp "$ROOT/scripts/validate_compose.py" "$FIXTURE_ROOT/scripts/validate_compose.py"
}

write_valid_compose() {
    mkdir -p "$(dirname "$1")"
    printf 'services:\n  app:\n    image: example/app:1\n' >"$1"
}

run_compose_validator() {
    "$PYTHON_BIN" "$FIXTURE_ROOT/scripts/validate_compose.py" \
        >"$TMP/$1.out" 2>&1
}

new_validator_root complete-inventory
write_valid_compose "$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator complete-inventory; then
    pass "the Compose validator accepts the complete canonical inventory"
else
    fail "the Compose validator rejected the complete canonical inventory"
fi

new_validator_root empty-inventory
if run_compose_validator empty-inventory; then
    fail "the Compose validator accepted an empty canonical inventory"
elif grep -Fq 'missing canonical Compose file' "$TMP/empty-inventory.out"; then
    pass "the Compose validator rejects an empty canonical inventory"
else
    fail "the Compose validator omitted the empty-inventory diagnostic"
fi

new_validator_root missing-inventory-entry
write_valid_compose "$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
if run_compose_validator missing-inventory-entry; then
    fail "the Compose validator accepted an incomplete canonical inventory"
elif grep -Fq 'e2e/docker-compose.scale.yml' \
    "$TMP/missing-inventory-entry.out"; then
    pass "the Compose validator identifies a missing canonical file"
else
    fail "the Compose validator omitted the missing canonical file"
fi

new_validator_root canonical-symlink
write_valid_compose "$FIXTURE_ROOT/outside.yml"
ln -s "$FIXTURE_ROOT/outside.yml" "$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator canonical-symlink; then
    fail "the Compose validator followed a canonical symlink"
elif grep -Eqi 'symlink|regular file|safely open' \
    "$TMP/canonical-symlink.out"; then
    pass "the Compose validator rejects canonical symlinks"
else
    fail "the Compose validator omitted its canonical-symlink diagnostic"
fi

new_validator_root byte-limit
write_valid_compose "$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
"$PYTHON_BIN" - "$FIXTURE_ROOT/docker-compose.e2e.yml" <<'PY'
from pathlib import Path
import sys

limit = 1_048_576
path = Path(sys.argv[1])
prefix = b"services:\n  app:\n    image: example/app:1\n#"
path.write_bytes(prefix + b"x" * (limit - len(prefix)))
PY
if run_compose_validator byte-limit; then
    pass "the Compose validator accepts a canonical file at its byte limit"
else
    fail "the Compose validator rejected a canonical file at its byte limit"
fi

printf 'x' >>"$FIXTURE_ROOT/docker-compose.e2e.yml"
if run_compose_validator byte-limit-plus-one; then
    fail "the Compose validator accepted a canonical file above its byte limit"
elif grep -Fq '1048576-byte limit' "$TMP/byte-limit-plus-one.out"; then
    pass "the Compose validator rejects a canonical file above its byte limit"
else
    fail "the Compose validator omitted its byte-limit diagnostic"
fi

new_validator_root multiple-documents
printf '%s\n' 'services: {app: {image: example/app:1}}' '---' \
    'services: {other: {image: example/app:2}}' \
    >"$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator multiple-documents; then
    fail "the Compose validator accepted multiple YAML documents"
elif grep -Fq 'document limit' "$TMP/multiple-documents.out"; then
    pass "the Compose validator enforces its YAML document limit"
else
    fail "the Compose validator omitted its YAML document-limit diagnostic"
fi

new_validator_root alias-limit
{
    printf 'defaults: &defaults {image: example/app:1}\nservices:\n'
    for index in $(seq 1 101); do
        printf '  app%s: *defaults\n' "$index"
    done
} >"$FIXTURE_ROOT/docker-compose.e2e.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator alias-limit; then
    fail "the Compose validator accepted an alias-expansion poison document"
elif grep -Fq 'alias limit' "$TMP/alias-limit.out"; then
    pass "the Compose validator enforces its YAML alias limit"
else
    fail "the Compose validator omitted its YAML alias-limit diagnostic"
fi

new_validator_root depth-limit
"$PYTHON_BIN" - "$FIXTURE_ROOT/docker-compose.e2e.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(
    "services:\n  app:\n    nested: " + "[" * 51 + "0" + "]" * 51 + "\n",
    encoding="utf-8",
)
PY
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator depth-limit; then
    fail "the Compose validator accepted an over-deep YAML document"
elif grep -Fq 'depth limit' "$TMP/depth-limit.out"; then
    pass "the Compose validator enforces its YAML depth limit"
else
    fail "the Compose validator omitted its YAML depth-limit diagnostic"
fi

new_validator_root node-limit
"$PYTHON_BIN" - "$FIXTURE_ROOT/docker-compose.e2e.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = ["services:", "  app:", "    image: example/app:1", "metadata:"]
lines.extend(f"  key{index}: value{index}" for index in range(5_001))
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.chaos.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.cluster.yml"
write_valid_compose "$FIXTURE_ROOT/e2e/docker-compose.scale.yml"
if run_compose_validator node-limit; then
    fail "the Compose validator accepted an over-large YAML node graph"
elif grep -Fq 'node limit' "$TMP/node-limit.out"; then
    pass "the Compose validator enforces its YAML node limit"
else
    fail "the Compose validator omitted its YAML node-limit diagnostic"
fi

if "$PYTHON_BIN" - "$ROOT/scripts/validate_compose.py" "$TMP" <<'PY'
import importlib.util
from pathlib import Path
import sys
from unittest.mock import patch

script = Path(sys.argv[1])
root = Path(sys.argv[2]) / "post-open-swap"
root.mkdir()
target = root / "docker-compose.yml"
target.write_text("services: {app: {image: example/app:1}}\n", encoding="utf-8")

spec = importlib.util.spec_from_file_location("validate_compose", script)
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_parse = module._parse
swapped = False

def swap_then_parse(source):
    global swapped
    if not swapped:
        target.rename(root / "displaced.yml")
        target.write_text(
            "services: {attacker: {image: example/attacker:latest}}\n",
            encoding="utf-8",
        )
        swapped = True
    return real_parse(source)

try:
    with patch.object(module, "_parse", side_effect=swap_then_parse):
        module.load_compose_path(target)
except OSError as error:
    if "changed" in str(error) or "replacement" in str(error):
        raise SystemExit(0)
raise SystemExit(1)
PY
then
    pass "the Compose reader rejects a post-open filename replacement"
else
    fail "the Compose reader accepted a post-open filename replacement"
fi

if "$PYTHON_BIN" - "$ROOT/scripts/validate_compose.py" "$TMP" <<'PY'
import importlib.util
from pathlib import Path
import sys

script = Path(sys.argv[1])
base = Path(sys.argv[2]) / "root-ancestor-swap"
repository = base / "outer" / "repo"
repository.mkdir(parents=True)

spec = importlib.util.spec_from_file_location("validate_compose", script)
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
chain = module.open_directory_chain(repository)
try:
    (base / "outer").rename(base / "displaced")
    repository.mkdir(parents=True)
    try:
        chain.revalidate()
    except OSError as error:
        if "changed" in str(error) or "replacement" in str(error):
            raise SystemExit(0)
finally:
    chain.close()
raise SystemExit(1)
PY
then
    pass "the Compose reader rejects a replaced root ancestor"
else
    fail "the Compose reader accepted a replaced root ancestor"
fi

printf '\nSummary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
