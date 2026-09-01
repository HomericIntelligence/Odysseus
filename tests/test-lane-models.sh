#!/usr/bin/env bash
# Tests for the ADR-020 lane-model pin (issue #465).
# Positive: real config parses, --table and --env produce expected output.
# Negative: malformed fixture (bad ID / missing lane) is rejected.
# AC3: one-line edit of one lane changes the loader output (round-trip).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT"

LOADER="tools/lane_models.py"
CONFIG="configs/lane-models.yaml"

info "loader accepts the real config (positive)"
if pixi run python "$LOADER" >/dev/null; then
    pass "loader validates $CONFIG"
else
    fail "loader rejected the real config"
fi

TABLE="$(pixi run python "$LOADER" 2>/dev/null || true)"
if grep -q "opencode/x-preview-f-free-high" <<<"$TABLE"; then
    pass "--table shows the planning lane ID"
else
    fail "--table missing planning lane ID"
fi

ENV_OUT="$(pixi run python "$LOADER" --env 2>/dev/null || true)"
ENV_COUNT="$(grep -c '^export HEPH_' <<<"$ENV_OUT" || true)"
if [ "$ENV_COUNT" -eq 5 ]; then
    pass "--env emits exactly 5 HEPH_*_MODEL exports"
else
    fail "--env emitted $ENV_COUNT exports (expected 5)"
fi

info "loader rejects broken fixtures (negative)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Malformed model ID (no provider/ prefix)
printf 'lanes:\n  planning: just-a-model\n  implementation: opencode/x-preview-f-free-medium\n  review: opencode/x-preview-f-free-low\n  mechanical: opencode/x-preview-f-free-low\n' > "$TMP/bad-id.yaml"
if pixi run python "$LOADER" --config "$TMP/bad-id.yaml" >/dev/null 2>&1; then
    fail "loader MISSED malformed model ID"
else
    pass "loader rejects malformed model ID"
fi

# Missing lane
printf 'lanes:\n  planning: opencode/x-preview-f-free-high\n  implementation: opencode/x-preview-f-free-medium\n  review: opencode/x-preview-f-free-low\n' > "$TMP/missing-lane.yaml"
if pixi run python "$LOADER" --config "$TMP/missing-lane.yaml" >/dev/null 2>&1; then
    fail "loader MISSED missing mechanical lane"
else
    pass "loader rejects config with a missing lane"
fi

# Extra unknown lane
printf 'lanes:\n  planning: opencode/x-preview-f-free-high\n  implementation: opencode/x-preview-f-free-medium\n  review: opencode/x-preview-f-free-low\n  mechanical: opencode/x-preview-f-free-low\n  sneaky: opencode/foo\n' > "$TMP/extra-lane.yaml"
if pixi run python "$LOADER" --config "$TMP/extra-lane.yaml" >/dev/null 2>&1; then
    fail "loader MISSED unexpected extra lane"
else
    pass "loader rejects config with an extra lane"
fi

info "one-line-edit property (AC3): editing one lane line changes the output"
sed 's|^  review:.*|  review: opencode/other-model-x|' "$CONFIG" > "$TMP/edited.yaml"
EDITED_ENV="$(pixi run python "$LOADER" --env --config "$TMP/edited.yaml" 2>/dev/null || true)"
if grep -q "^export HEPH_REVIEWER_MODEL=opencode/other-model-x$" <<<"$EDITED_ENV" \
    && grep -q "^export HEPH_PLANNER_MODEL=opencode/x-preview-f-free-high$" <<<"$EDITED_ENV"; then
    pass "single-line edit changes only that lane's export"
else
    fail "one-line edit did not propagate to loader output"
fi

summary
exit_code   # e2e/lib/common.sh:41 -- returns non-zero if any fail
