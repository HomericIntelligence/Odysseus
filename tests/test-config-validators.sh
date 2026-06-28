#!/usr/bin/env bash
# Negative + positive tests for the config validators (issue #198, TDD).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT"

info "validators accept the real configs (positive)"
if python3 scripts/validate_nats_config.py >/dev/null; then pass "NATS validator accepts configs/nats/*.conf"; else fail "NATS validator rejected real configs"; fi
if python3 scripts/validate_compose.py >/dev/null; then pass "compose validator accepts docker-compose*.yml"; else fail "compose validator rejected real files"; fi

info "validators reject broken fixtures (negative)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
then pass "NATS validator rejects unbalanced braces"; else fail "NATS validator MISSED unbalanced braces"; fi

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

summary
exit_code
