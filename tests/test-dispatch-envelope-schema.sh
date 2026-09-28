#!/usr/bin/env bash
# Tests for the hi/v1 dispatch-envelope JSON Schema (issue #466, ADR-020 M0-2).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT" || exit 1

SCHEMA="configs/schemas/dispatch-envelope.hi-v1.schema.json"

# The hi/v1 artifact includes the description-only governance corrections from
# merged PR #514, commit 5cc09e7d6611d2edbfa664f17097d345aba50aa6.
# Its validation rules are unchanged from the original frozen contract.
# This byte oracle protects the reviewed versioned wire artifact independently
# of the optional jsonschema package.
EXPECTED_SCHEMA_SHA256="09d3d7693ce04933a2245e1bb8754d347a200fd02b8c69b66df257943084c912"

info "frozen hi/v1 schema bytes"
actual_schema_sha256="$(python3 - "$SCHEMA" <<'PY'
import hashlib
from pathlib import Path
import sys

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
if [ "$actual_schema_sha256" = "$EXPECTED_SCHEMA_SHA256" ]; then
    pass "dispatch-envelope.hi-v1 matches its frozen origin/main bytes"
else
    fail "dispatch-envelope.hi-v1 differs from its frozen origin/main bytes"
fi

if ! python3 -c "import jsonschema, rfc3339_validator" >/dev/null 2>&1; then
    fail "python jsonschema and RFC 3339 format validation are required"
    summary
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

validate() {  # validate <payload-json-file> -> rc 0 if valid against $SCHEMA
    python3 - "$SCHEMA" "$1" <<'PY'
import json
import sys
import jsonschema

with open(sys.argv[1]) as f:
    schema = json.load(f)
with open(sys.argv[2]) as f:
    payload = json.load(f)
validator = jsonschema.Draft202012Validator(
    schema,
    format_checker=jsonschema.FormatChecker(),
)
validator.validate(payload)
PY
}

info "schema itself is a valid draft 2020-12 schema"
if python3 -c "import json, jsonschema as j; j.Draft202012Validator.check_schema(json.load(open('$SCHEMA')))"; then
    pass "dispatch-envelope.hi-v1 passes Draft202012Validator.check_schema"
else
    fail "dispatch-envelope.hi-v1 fails check_schema"
fi

if python3 - <<'PY'
import jsonschema

checker = jsonschema.FormatChecker()
raise SystemExit(
    0
    if checker.conforms("2026-08-25T12:00:00Z", "date-time")
    and not checker.conforms("not-a-timestamp", "date-time")
    and checker.conforms("0b9e6cde-1111-4a2a-8d3e-000000000001", "uuid")
    and not checker.conforms("not-a-uuid", "uuid")
    else 1
)
PY
then
    pass "date-time and UUID format checkers are active"
else
    fail "date-time or UUID format checker is unavailable"
fi

info "positive fixtures"

cat > "$TMP/planning.json" <<'JSON'
{
  "schema": "hi/v1",
  "ts": "2026-08-25T12:00:00Z",
  "msg_id": "0b9e6cde-1111-4a2a-8d3e-000000000001",
  "repo": "HomericIntelligence/Odysseus",
  "issue": 466,
  "branch": "466-auto-impl",
  "epic_key": "Odysseus-450",
  "base_branch": "main",
  "domain": "pipeline",
  "role": "chief-architect",
  "stage": "planning",
  "attempt": 1,
  "budgets": {
    "clone": 2,
    "plan": 2,
    "plan_review_iter": 3,
    "plan_cycles": 2,
    "implement": 2,
    "rebase_conflict": 2,
    "test_fix": 1,
    "pr_review_iter": 3,
    "pr_review_hard": 6,
    "merge": 5
  }
}
JSON

cat > "$TMP/pr_review_remediation.json" <<'JSON'
{
  "schema": "hi/v1",
  "ts": "2026-08-25T12:05:00Z",
  "msg_id": "0b9e6cde-1111-4a2a-8d3e-000000000002",
  "repo": "HomericIntelligence/Odysseus",
  "issue": 467,
  "branch": "467-auto-impl",
  "stage": "pr_review",
  "attempt": 2,
  "budgets": {
    "clone": 2,
    "plan": 2,
    "plan_review_iter": 3,
    "plan_cycles": 2,
    "implement": 2,
    "rebase_conflict": 2,
    "test_fix": 1,
    "pr_review_iter": 3,
    "pr_review_hard": 6,
    "merge": 5
  },
  "verdict": "no_go",
  "remediation": {
    "reason": "CI failing on PR #42",
    "evidence": ["check lint: 1 error in src/a.py", "review thread: missing test"]
  }
}
JSON

if validate "$TMP/planning.json"; then pass "full planning-stage packet validates"; else fail "planning packet REJECTED"; fi
if validate "$TMP/pr_review_remediation.json"; then pass "pr_review no_go remediation packet validates"; else fail "remediation packet REJECTED"; fi

info "negative fixtures"

# Missing required stage field
python3 - "$TMP" <<'PY'
import json
p = json.load(open(f"{__import__('sys').argv[1]}/planning.json"))
del p["stage"]
json.dump(p, open(f"{__import__('sys').argv[1]}/missing_stage.json", "w"))
PY
if validate "$TMP/missing_stage.json" 2>/dev/null; then fail "schema MISSED missing stage"; else pass "packet without stage rejected"; fi

# Unknown budget counter name (closed object)
python3 - "$TMP" <<'PY'
import json, sys
p = json.load(open(f"{sys.argv[1]}/planning.json"))
p["budgets"]["madeup_counter"] = 9
json.dump(p, open(f"{sys.argv[1]}/bad_budget_name.json", "w"))
PY
if validate "$TMP/bad_budget_name.json" 2>/dev/null; then fail "schema MISSED unknown budget counter"; else pass "unknown budget counter rejected"; fi

# attempt below minimum
python3 - "$TMP" <<'PY'
import json, sys
p = json.load(open(f"{sys.argv[1]}/planning.json"))
p["attempt"] = 0
json.dump(p, open(f"{sys.argv[1]}/zero_attempt.json", "w"))
PY
if validate "$TMP/zero_attempt.json" 2>/dev/null; then fail "schema MISSED attempt=0"; else pass "attempt=0 rejected"; fi

# Missing base envelope fields (schema/ts/msg_id)
python3 - "$TMP" <<'PY'
import json, sys
p = json.load(open(f"{sys.argv[1]}/planning.json"))
for k in ("schema", "ts", "msg_id"):
    del p[k]
json.dump(p, open(f"{sys.argv[1]}/missing_envelope.json", "w"))
PY
if validate "$TMP/missing_envelope.json" 2>/dev/null; then fail "schema MISSED missing envelope fields"; else pass "missing envelope fields rejected"; fi

# Invalid date-time and UUID formats must not pass as ordinary strings.
python3 - "$TMP" <<'PY'
import json, sys
p = json.load(open(f"{sys.argv[1]}/planning.json"))
p["ts"] = "not-a-timestamp"
json.dump(p, open(f"{sys.argv[1]}/bad_timestamp.json", "w"))
p = json.load(open(f"{sys.argv[1]}/planning.json"))
p["msg_id"] = "not-a-uuid"
json.dump(p, open(f"{sys.argv[1]}/bad_message_id.json", "w"))
PY
if validate "$TMP/bad_timestamp.json" 2>/dev/null; then fail "schema MISSED invalid date-time"; else pass "invalid date-time rejected"; fi
if validate "$TMP/bad_message_id.json" 2>/dev/null; then fail "schema MISSED invalid UUID"; else pass "invalid UUID rejected"; fi

# Invalid verdict value
python3 - "$TMP" <<'PY'
import json, sys
p = json.load(open(f"{sys.argv[1]}/planning.json"))
p["verdict"] = "maybe"
json.dump(p, open(f"{sys.argv[1]}/bad_verdict.json", "w"))
PY
if validate "$TMP/bad_verdict.json" 2>/dev/null; then fail "schema MISSED invalid verdict"; else pass "invalid verdict rejected"; fi

summary
exit_code
