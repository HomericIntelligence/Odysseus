#!/usr/bin/env bash
# Behavior tests for separate runtime-role and instruction-role validation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
CHECKER="$ROOT/scripts/check-hierarchy-sync.sh"
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

TMP_PARENT="$(CDPATH='' cd -P -- "${TMPDIR:-/tmp}" && pwd -P)"
TMP_PREFIX="${TMP_PARENT%/}/odysseus-hierarchy-sync."
TMP=""
TMP_VALID=false
suite_completed=0

make_fixture_directory() {
    local prefix="$1" created suffix
    if ! created="$(mktemp -d "${prefix}XXXXXX")"; then
        return 1
    fi
    suffix="${created#"$prefix"}"
    if [ -z "$created" ] || [ "$suffix" = "$created" ] || [ -z "$suffix" ] \
        || [ ! -d "$created" ] || [ -L "$created" ]; then
        return 1
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s\n' "$created"
}

cleanup_fixture() {
    local incoming_status="$1" suffix cleanup_status=0
    trap - EXIT
    if [ "$TMP_VALID" != true ]; then
        cleanup_status=79
    else
        suffix="${TMP#"$TMP_PREFIX"}"
        if [ -z "$TMP" ] || [ "$suffix" = "$TMP" ] || [ -z "$suffix" ] \
            || [ ! -d "$TMP" ] || [ -L "$TMP" ]; then
            printf 'ERROR: refusing unsafe hierarchy fixture cleanup: %s\n' \
                "$TMP" >&2
            cleanup_status=79
        else
            case "$suffix" in
                *[!A-Za-z0-9]*)
                    printf 'ERROR: refusing unsafe hierarchy fixture cleanup: %s\n' \
                        "$TMP" >&2
                    cleanup_status=79
                    ;;
            esac
        fi
        if [ "$cleanup_status" -eq 0 ] && ! rm -rf -- "$TMP"; then
            printf 'ERROR: failed to remove hierarchy fixture: %s\n' "$TMP" >&2
            cleanup_status=79
        elif [ "$cleanup_status" -eq 0 ] \
            && [ "${ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE:-0}" = 1 ]; then
            printf '%s\n' 'ERROR: controlled hierarchy cleanup failure' >&2
            cleanup_status=79
        fi
    fi
    if [ "$incoming_status" -ne 0 ]; then
        exit "$incoming_status"
    fi
    if [ "$suite_completed" -ne 1 ]; then
        printf '%s\n' 'ERROR: hierarchy suite did not reach its completion marker' >&2
        exit 78
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        exit "$cleanup_status"
    fi
    exit 0
}

if ! TMP="$(make_fixture_directory "$TMP_PREFIX")"; then
    printf '%s\n' 'ERROR: could not create a safe hierarchy fixture' >&2
    exit 1
fi
TMP_VALID=true
trap 'cleanup_fixture "$?"' EXIT

case "${ODYSSEUS_TEST_HARNESS_PROBE:-}" in
    fatal) exit 73 ;;
    incomplete) exit 0 ;;
    complete)
        suite_completed=1
        exit 0
        ;;
esac

ODYSSEY_ROLES=(
    chief-architect
    implementation-engineer
    ci-failure-analyzer
    code-review-orchestrator
    general-review-specialist
    mojo-language-review-specialist
    numerical-stability-specialist
    security-review-specialist
    test-review-specialist
)

new_repo() {
    local path="$1"
    mkdir -p "$path"
    git -C "$path" init -q
}

write_runtime_role() {
    local file="$1" name="$2" extra="${3:-}"
    mkdir -p "$(dirname "$file")"
    {
        printf '%s\n' \
            '---' \
            "name: $name" \
            'level: 1' \
            'phase: runtime' \
            'tools: [Read, Edit]' \
            'model: runtime-model' \
            'delegates_to: []' \
            'receives_from: []'
        if [ -n "$extra" ]; then
            printf '%s\n' "$extra"
        fi
        printf '%s\n' '---' '' 'Runtime role fixture.'
    } > "$file"
}

write_instruction_role() {
    local file="$1" name="$2"
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<EOF
---
name: $name
level: 7
phase: repository-instruction
tools: [Read]
model: instruction-model
delegates_to: [repository-owner]
receives_from: [user]
---

Instruction role fixture. Its metadata is intentionally different from a
runtime role that has the same name.
EOF
}

write_odyssey_inventory() {
    local repo="$1" role
    for role in "${ODYSSEY_ROLES[@]}"; do
        write_instruction_role \
            "$repo/research/Odyssey/.claude/agents/$role.md" "$role"
    done
}

# shellcheck disable=SC2094  # basename reads only the name, never file content.
write_runtime_consumer_tag() {
    local file="$1" tag="$2" extra="${3:-}"
    mkdir -p "$(dirname "$file")"
    {
        printf '%s\n' \
            'apiVersion: myrmidons/v1' \
            'kind: Agent' \
            'metadata:' \
            "  name: $(basename "$file" .yaml)" \
            'spec:' \
            '  program: claude-code' \
            '  model: explicit-fixture-model' \
            '  tags:' \
            '    - mesh' \
            "    - $tag"
        if [ -n "$extra" ]; then
            printf '  %s\n' "$extra"
        fi
    } > "$file"
}

write_runtime_consumer() {
    local file="$1" pool="$2" extra="${3:-}"
    write_runtime_consumer_tag "$file" "\"pool:$pool\"" "$extra"
}

write_valid_runtime_inventory() {
    local repo="$1"
    write_runtime_role \
        "$repo/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
        chief-architect
    write_runtime_role \
        "$repo/provisioning/Myrmidons/agents/hierarchy/task-agent.md" \
        task-agent
    write_runtime_consumer \
        "$repo/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
        pipeline.chief-architect
    write_runtime_consumer \
        "$repo/provisioning/Myrmidons/agents/hermes/mesh-research-chief.yaml" \
        research.chief-architect
    write_runtime_consumer \
        "$repo/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml" \
        pipeline.task-agent
}

write_valid_repo() {
    local repo="$1"
    new_repo "$repo"
    write_valid_runtime_inventory "$repo"
    write_odyssey_inventory "$repo"
}

replace_fixture_line() {
    local file="$1" original="$2" replacement="$3" line
    local replacement_file="$file.replacement"
    : > "$replacement_file"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$original" ]; then
            printf '%s\n' "$replacement" >> "$replacement_file"
        else
            printf '%s\n' "$line" >> "$replacement_file"
        fi
    done < "$file"
    mv "$replacement_file" "$file"
}

run_check() {
    local repo="$1"
    shift
    set +e
    CHECK_OUTPUT="$(cd "$repo" && bash "$CHECKER" "$@" 2>&1)"
    CHECK_STATUS=$?
    set -e
}

run_check_external_bound() {
    local repo="$1"
    shift
    set +e
    CHECK_OUTPUT="$(/usr/bin/python3 -I -S - "$repo" "$CHECKER" "$@" 2>&1 <<'PY'
import subprocess
import sys


try:
    result = subprocess.run(
        ["/bin/bash", sys.argv[2], *sys.argv[3:]],
        cwd=sys.argv[1],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=3,
        check=False,
    )
except subprocess.TimeoutExpired as error:
    if error.stdout:
        sys.stdout.buffer.write(error.stdout)
    raise SystemExit(124) from error
sys.stdout.buffer.write(result.stdout)
raise SystemExit(result.returncode)
PY
)"
    CHECK_STATUS=$?
    set -e
}

run_check_with_path() {
    local repo="$1" path_prefix="$2"
    shift 2
    set +e
    CHECK_OUTPUT="$(cd "$repo" && PATH="$path_prefix:$PATH" bash "$CHECKER" "$@" 2>&1)"
    CHECK_STATUS=$?
    set -e
}

assert_drift() {
    local description="$1" expected="$2"
    if [ "$CHECK_STATUS" -eq 1 ] \
        && grep -q '^hierarchy_available=true$' <<<"$CHECK_OUTPUT" \
        && grep -q '^hierarchy_drift=true$' <<<"$CHECK_OUTPUT" \
        && grep -Fq "$expected" <<<"$CHECK_OUTPUT"; then
        pass "$description"
    else
        fail "$description returned $CHECK_STATUS without the expected drift"
    fi
}

assert_unavailable() {
    local description="$1"
    if [ "$CHECK_STATUS" -eq 2 ] \
        && grep -q '^hierarchy_available=false$' <<<"$CHECK_OUTPUT" \
        && grep -q '^hierarchy_drift=unknown$' <<<"$CHECK_OUTPUT"; then
        pass "$description"
    else
        fail "$description returned $CHECK_STATUS without unavailable status"
    fi
}

checker_with_limit() {
    local destination="$1" original="$2" replacement="$3"
    cp "$CHECKER" "$destination"
    python3 - "$destination" "$original" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
if source.count(sys.argv[2]) != 1:
    raise SystemExit(f"hierarchy limit seam changed: {sys.argv[2]}")
path.write_text(source.replace(sys.argv[2], sys.argv[3]), encoding="utf-8")
PY
}

info "help and invocation errors preserve the public exit contract"
set +e
HELP_OUTPUT="$(bash "$CHECKER" --help 2>&1)"
HELP_STATUS=$?
SURPLUS_OUTPUT="$(bash "$CHECKER" --help unexpected 2>&1)"
SURPLUS_STATUS=$?
set -e
if [ "$HELP_STATUS" -eq 0 ] \
    && grep -q 'check-hierarchy-sync.sh \[--ci\]' <<<"$HELP_OUTPUT" \
    && ! grep -Eq '^(set -|CI_MODE=|case |REPO_ROOT=)' <<<"$HELP_OUTPUT"; then
    pass "help output is complete and does not expose implementation code"
else
    fail "help output is incomplete or exposes implementation code"
fi
if [ "$SURPLUS_STATUS" -eq 2 ] \
    && grep -q 'unexpected argument' <<<"$SURPLUS_OUTPUT"; then
    pass "surplus command-line arguments are rejected"
else
    fail "surplus command-line arguments returned $SURPLUS_STATUS"
fi

info "uninitialized or incomplete owner inputs are unavailable"
missing_runtime="$TMP/missing-runtime"
new_repo "$missing_runtime"
write_odyssey_inventory "$missing_runtime"
run_check "$missing_runtime" --ci
assert_unavailable "missing Myrmidons runtime definitions are unavailable"

missing_consumers="$TMP/missing-consumers"
new_repo "$missing_consumers"
write_runtime_role \
    "$missing_consumers/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect
write_odyssey_inventory "$missing_consumers"
run_check "$missing_consumers" --ci
assert_unavailable "missing provisioned pool consumers are unavailable"

missing_odyssey="$TMP/missing-odyssey"
new_repo "$missing_odyssey"
write_valid_runtime_inventory "$missing_odyssey"
run_check "$missing_odyssey" --ci
assert_unavailable "missing Odyssey instruction definitions are unavailable"

info "runtime and instruction roles have separate owners and namespaces"
separate_owners="$TMP/separate-owners"
write_valid_repo "$separate_owners"
run_check "$separate_owners" --ci
if [ "$CHECK_STATUS" -eq 0 ] \
    && grep -q '^hierarchy_available=true$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_runtime_consumers=3$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_instruction_roles=9$' <<<"$CHECK_OUTPUT"; then
    pass "legitimate owner-specific metadata and shared role names pass"
else
    fail "separate role owners returned $CHECK_STATUS or an incomplete summary"
fi

info "Odyssey must contain exactly the nine retained instruction roles"
missing_instruction="$TMP/missing-instruction"
write_valid_repo "$missing_instruction"
rm "$missing_instruction/research/Odyssey/.claude/agents/security-review-specialist.md"
run_check "$missing_instruction" --ci
assert_drift \
    "a missing retained instruction role fails" \
    "missing retained Odyssey instruction role security-review-specialist"

surplus_instruction="$TMP/surplus-instruction"
write_valid_repo "$surplus_instruction"
write_instruction_role \
    "$surplus_instruction/research/Odyssey/.claude/agents/architecture-design.md" \
    architecture-design
run_check "$surplus_instruction" --ci
assert_drift \
    "a surplus Odyssey instruction role fails" \
    "surplus Odyssey instruction role architecture-design"

duplicate_instruction="$TMP/duplicate-instruction"
write_valid_repo "$duplicate_instruction"
write_instruction_role \
    "$duplicate_instruction/research/Odyssey/.claude/agents/duplicate.md" \
    chief-architect
run_check "$duplicate_instruction" --ci
assert_drift \
    "a duplicate Odyssey instruction name fails" \
    "duplicate frontmatter name chief-architect"

info "runtime roles bind to explicit provisioned pool consumers"
unquoted_pool="$TMP/unquoted-pool"
write_valid_repo "$unquoted_pool"
write_runtime_consumer_tag \
    "$unquoted_pool/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml" \
    'pool:pipeline.task-agent'
run_check "$unquoted_pool" --ci
if [ "$CHECK_STATUS" -eq 0 ] \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_runtime_consumers=3$' <<<"$CHECK_OUTPUT"; then
    pass "an unquoted pool tag is a valid YAML text scalar"
else
    fail "an unquoted pool tag returned $CHECK_STATUS or an invalid summary"
fi

missing_runtime_role="$TMP/missing-runtime-role"
write_valid_repo "$missing_runtime_role"
write_runtime_consumer \
    "$missing_runtime_role/provisioning/Myrmidons/agents/hermes/mesh-plan-review.yaml" \
    pipeline.plan-reviewer
run_check "$missing_runtime_role" --ci
assert_drift \
    "a pool consumer without a runtime definition fails" \
    "pool consumer pipeline.plan-reviewer has no Myrmidons runtime definition"

orphan_runtime_role="$TMP/orphan-runtime-role"
write_valid_repo "$orphan_runtime_role"
write_runtime_role \
    "$orphan_runtime_role/provisioning/Myrmidons/agents/hierarchy/orphan.md" \
    orphan
run_check "$orphan_runtime_role" --ci
assert_drift \
    "a runtime definition without a current pool consumer fails" \
    "Myrmidons runtime role orphan has no provisioned pool consumer"

malformed_pool="$TMP/malformed-pool"
write_valid_repo "$malformed_pool"
write_runtime_consumer \
    "$malformed_pool/provisioning/Myrmidons/agents/hermes/mesh-invalid.yaml" \
    pipeline.too.many-parts
run_check "$malformed_pool" --ci
assert_drift \
    "a malformed pool consumer reference fails" \
    "invalid pool consumer reference pool:pipeline.too.many-parts"

mapping_pool="$TMP/mapping-pool"
write_valid_repo "$mapping_pool"
write_runtime_consumer_tag \
    "$mapping_pool/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml" \
    'pool: pipeline.task-agent'
run_check "$mapping_pool" --ci
assert_drift \
    "a block-mapping pool tag cannot masquerade as a text tag" \
    "pool-like tag must be a text scalar"

flow_mapping_pool="$TMP/flow-mapping-pool"
write_valid_repo "$flow_mapping_pool"
write_runtime_consumer_tag \
    "$flow_mapping_pool/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml" \
    '{pool: pipeline.task-agent}'
run_check "$flow_mapping_pool" --ci
assert_drift \
    "a flow-mapping pool tag cannot masquerade as a text tag" \
    "pool-like tag must be a text scalar"

spaced_mapping_pool="$TMP/spaced-mapping-pool"
write_valid_repo "$spaced_mapping_pool"
write_runtime_consumer_tag \
    "$spaced_mapping_pool/provisioning/Myrmidons/agents/hermes/mesh-spaced-pool.yaml" \
    'pool : pipeline.task-agent'
run_check "$spaced_mapping_pool" --ci
assert_drift \
    "a spaced pool mapping cannot bypass semantic discovery" \
    "pool-like tag must be a text scalar"

quoted_mapping_pool="$TMP/quoted-mapping-pool"
write_valid_repo "$quoted_mapping_pool"
write_runtime_consumer_tag \
    "$quoted_mapping_pool/provisioning/Myrmidons/agents/hermes/mesh-quoted-pool.yaml" \
    '"pool": pipeline.task-agent'
run_check "$quoted_mapping_pool" --ci
assert_drift \
    "a quoted pool mapping cannot bypass semantic discovery" \
    "pool-like tag must be a text scalar"

encoded_pool="$TMP/encoded-pool"
write_valid_repo "$encoded_pool"
write_runtime_consumer_tag \
    "$encoded_pool/provisioning/Myrmidons/agents/hermes/mesh-encoded-pool.yaml" \
    '"\x70ool:pipeline.undefined-role"'
run_check "$encoded_pool" --ci
assert_drift \
    "a YAML-escaped pool tag is decoded before role validation" \
    "pool consumer pipeline.undefined-role has no Myrmidons runtime definition"

malformed_no_pool="$TMP/malformed-no-pool"
write_valid_repo "$malformed_no_pool"
write_runtime_consumer_tag \
    "$malformed_no_pool/provisioning/Myrmidons/agents/hermes/malformed-no-pool.yaml" \
    '[mesh'
run_check "$malformed_no_pool" --ci
assert_drift \
    "a malformed authored manifest without a visible pool token fails" \
    "invalid runtime manifest YAML"

duplicate_manifest_key="$TMP/duplicate-manifest-key"
write_valid_repo "$duplicate_manifest_key"
write_runtime_consumer_tag \
    "$duplicate_manifest_key/provisioning/Myrmidons/agents/hermes/duplicate-tags.yaml" \
    mesh-worker \
    'tags: [mesh]'
run_check "$duplicate_manifest_key" --ci
assert_drift \
    "a duplicate key in an otherwise unrelated manifest fails" \
    "invalid runtime manifest YAML"

no_separator_definition="$TMP/no-separator-definition"
write_valid_repo "$no_separator_definition"
replace_fixture_line \
    "$no_separator_definition/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    'name: chief-architect' \
    'name:chief-architect'
run_check "$no_separator_definition" --ci
assert_drift \
    "a definition mapping value requires separation after its colon" \
    "invalid YAML frontmatter"

no_separator_manifest="$TMP/no-separator-manifest"
write_valid_repo "$no_separator_manifest"
replace_fixture_line \
    "$no_separator_manifest/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    'kind: Agent' \
    'kind:Agent'
run_check "$no_separator_manifest" --ci
assert_drift \
    "a manifest mapping value requires separation after its colon" \
    "invalid runtime manifest YAML"

no_separator_nested_mapping="$TMP/no-separator-nested-mapping"
write_valid_repo "$no_separator_nested_mapping"
replace_fixture_line \
    "$no_separator_nested_mapping/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    '  program: claude-code' \
    '  program:claude-code'
run_check "$no_separator_nested_mapping" --ci
assert_drift \
    "a nested authored mapping value requires separation after its colon" \
    "invalid runtime manifest YAML"

no_separator_flow_tag="$TMP/no-separator-flow-tag"
write_valid_repo "$no_separator_flow_tag"
write_runtime_consumer_tag \
    "$no_separator_flow_tag/provisioning/Myrmidons/agents/hermes/no-separator-flow-tag.yaml" \
    '{tags:["pool:pipeline.task-agent"]}'
run_check "$no_separator_flow_tag" --ci
assert_drift \
    "a flow-mapping tag value requires separation after its colon" \
    "invalid runtime manifest YAML"

no_separator_definition_flow="$TMP/no-separator-definition-flow"
write_valid_repo "$no_separator_definition_flow"
write_runtime_role \
    "$no_separator_definition_flow/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect \
    'routing: {role:chief-architect}'
run_check "$no_separator_definition_flow" --ci
assert_drift \
    "a definition flow-mapping value requires separation after its colon" \
    "invalid YAML frontmatter"

no_separator_manifest_flow="$TMP/no-separator-manifest-flow"
write_valid_repo "$no_separator_manifest_flow"
write_runtime_consumer \
    "$no_separator_manifest_flow/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    pipeline.chief-architect \
    'routing: {role:chief-architect}'
run_check "$no_separator_manifest_flow" --ci
assert_drift \
    "a manifest flow-mapping value requires separation after its colon" \
    "invalid runtime manifest YAML"

undeclared_pool="$TMP/undeclared-pool"
write_valid_repo "$undeclared_pool"
write_runtime_consumer_tag \
    "$undeclared_pool/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml" \
    mesh-worker \
    'poolSource: pool:pipeline.task-agent'
run_check "$undeclared_pool" --ci
assert_drift \
    "a pool reference outside spec.tags is not a consumer declaration" \
    "pool consumer reference is outside spec.tags"

info "only explicit cross-owner mappings fail"
definition_mapping="$TMP/definition-mapping"
write_valid_repo "$definition_mapping"
write_runtime_role \
    "$definition_mapping/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect \
    'odyssey_instruction_role: chief-architect'
run_check "$definition_mapping" --ci
assert_drift \
    "an explicit runtime-definition mapping to Odyssey fails" \
    "unapproved Odyssey instruction reference"

manifest_mapping="$TMP/manifest-mapping"
write_valid_repo "$manifest_mapping"
write_runtime_consumer \
    "$manifest_mapping/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    pipeline.chief-architect \
    'instructionSource: research/Odyssey/.claude/agents/chief-architect.md'
run_check "$manifest_mapping" --ci
assert_drift \
    "an explicit runtime-manifest reference to Odyssey fails" \
    "unapproved Odyssey instruction reference"

definition_role_mapping="$TMP/definition-role-mapping"
write_valid_repo "$definition_role_mapping"
write_runtime_role \
    "$definition_role_mapping/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect \
    'odyssey_role: chief-architect'
run_check "$definition_role_mapping" --ci
assert_drift \
    "an explicit odyssey_role definition mapping fails" \
    "unapproved Odyssey instruction reference"

manifest_agent_mapping="$TMP/manifest-agent-mapping"
write_valid_repo "$manifest_agent_mapping"
write_runtime_consumer \
    "$manifest_agent_mapping/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    pipeline.chief-architect \
    'odyssey_agent: chief-architect'
run_check "$manifest_agent_mapping" --ci
assert_drift \
    "an explicit odyssey_agent manifest mapping fails" \
    "unapproved Odyssey instruction reference"

definition_reverse_mapping="$TMP/definition-reverse-mapping"
write_valid_repo "$definition_reverse_mapping"
write_runtime_role \
    "$definition_reverse_mapping/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect \
    'role_odyssey: chief-architect'
run_check "$definition_reverse_mapping" --ci
assert_drift \
    "an explicit role_odyssey definition mapping fails" \
    "unapproved Odyssey instruction reference"

manifest_reverse_mapping="$TMP/manifest-reverse-mapping"
write_valid_repo "$manifest_reverse_mapping"
write_runtime_consumer \
    "$manifest_reverse_mapping/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    pipeline.chief-architect \
    'agent_odyssey: chief-architect'
run_check "$manifest_reverse_mapping" --ci
assert_drift \
    "an explicit agent_odyssey manifest mapping fails" \
    "unapproved Odyssey instruction reference"

direct_owner_mapping="$TMP/direct-owner-mapping"
write_valid_repo "$direct_owner_mapping"
write_runtime_role \
    "$direct_owner_mapping/provisioning/Myrmidons/agents/hierarchy/chief-architect.md" \
    chief-architect \
    'odyssey: chief-architect'
run_check "$direct_owner_mapping" --ci
assert_drift \
    "a direct odyssey definition mapping fails" \
    "unapproved Odyssey instruction reference"

instruction_owner_mapping="$TMP/instruction-owner-mapping"
write_valid_repo "$instruction_owner_mapping"
write_runtime_consumer \
    "$instruction_owner_mapping/provisioning/Myrmidons/agents/hermes/mesh-pipeline-chief.yaml" \
    pipeline.chief-architect \
    'instruction_owner: Odyssey'
run_check "$instruction_owner_mapping" --ci
assert_drift \
    "an Odyssey instruction_owner manifest mapping fails" \
    "unapproved Odyssey instruction reference"

info "required paths stay bound to direct files and directories"
for symlink_mode in runtime-file runtime-directory instruction-file \
    instruction-directory consumer-file consumer-directory; do
    symlink_repo="$TMP/symlink-$symlink_mode"
    write_valid_repo "$symlink_repo"
    case "$symlink_mode" in
        runtime-file)
            target="$symlink_repo/provisioning/Myrmidons/agents/hierarchy/task-agent.md"
            mv "$target" "$symlink_repo/runtime-target.md"
            ln -s "$symlink_repo/runtime-target.md" "$target"
            ;;
        runtime-directory)
            target="$symlink_repo/provisioning/Myrmidons/agents/hierarchy"
            mv "$target" "$symlink_repo/runtime-hierarchy"
            ln -s "$symlink_repo/runtime-hierarchy" "$target"
            ;;
        instruction-file)
            target="$symlink_repo/research/Odyssey/.claude/agents/test-review-specialist.md"
            mv "$target" "$symlink_repo/instruction-target.md"
            ln -s "$symlink_repo/instruction-target.md" "$target"
            ;;
        instruction-directory)
            target="$symlink_repo/research/Odyssey/.claude/agents"
            mv "$target" "$symlink_repo/instruction-agents"
            ln -s "$symlink_repo/instruction-agents" "$target"
            ;;
        consumer-file)
            target="$symlink_repo/provisioning/Myrmidons/agents/hermes/mesh-pipeline-task.yaml"
            mv "$target" "$symlink_repo/consumer-target.yaml"
            ln -s "$symlink_repo/consumer-target.yaml" "$target"
            ;;
        consumer-directory)
            target="$symlink_repo/provisioning/Myrmidons/agents/hermes"
            mv "$target" "$symlink_repo/consumer-hermes"
            ln -s "$symlink_repo/consumer-hermes" "$target"
            ;;
    esac
    run_check "$symlink_repo" --ci
    assert_unavailable "$symlink_mode symlink is unavailable"
done

info "read and parse failures cannot become passing comparisons"
hostile_tools="$TMP/hostile-tools"
write_valid_repo "$hostile_tools"
mkdir -p "$hostile_tools/bin"
cat > "$hostile_tools/bin/git" <<'EOF'
#!/usr/bin/env bash
: > "${HIERARCHY_GIT_MARKER:?}"
exec "${HIERARCHY_REAL_GIT:?}" "$@"
EOF
cat > "$hostile_tools/bin/python3" <<'EOF'
#!/usr/bin/env bash
: > "${HIERARCHY_PYTHON_MARKER:?}"
printf '%s\n' \
    'hierarchy_receipt={"result":"clean","schema":"odysseus.hierarchy-check","version":1}'
EOF
chmod +x "$hostile_tools/bin/git" "$hostile_tools/bin/python3"
HIERARCHY_GIT_MARKER="$hostile_tools/git-invoked" \
HIERARCHY_PYTHON_MARKER="$hostile_tools/python-invoked" \
HIERARCHY_REAL_GIT="$(command -v git)" \
    run_check_with_path "$hostile_tools" "$hostile_tools/bin" --ci
if [ "$CHECK_STATUS" -eq 0 ] \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT" \
    && [ ! -e "$hostile_tools/git-invoked" ] \
    && [ ! -e "$hostile_tools/python-invoked" ]; then
    pass "ambient Git and Python executables have zero effects"
else
    fail "an ambient executable ran or changed the hierarchy result"
fi

hostile_builtins="$TMP/hostile-builtins"
write_valid_repo "$hostile_builtins"
# shellcheck disable=SC2329  # Exported into the checker subprocess.
cd() {
    : > "${HIERARCHY_CD_MARKER:?}"
    return 90
}
# shellcheck disable=SC2329  # Exported into the checker subprocess.
pwd() {
    : > "${HIERARCHY_PWD_MARKER:?}"
    return 91
}
export -f cd pwd
export HIERARCHY_CD_MARKER="$hostile_builtins/cd-invoked"
export HIERARCHY_PWD_MARKER="$hostile_builtins/pwd-invoked"
run_check_external_bound "$hostile_builtins" --ci
unset -f cd pwd
unset HIERARCHY_CD_MARKER HIERARCHY_PWD_MARKER
if [ "$CHECK_STATUS" -eq 0 ] \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT" \
    && [ ! -e "$hostile_builtins/cd-invoked" ] \
    && [ ! -e "$hostile_builtins/pwd-invoked" ]; then
    pass "exported cd and pwd functions have zero effects"
else
    fail "an exported cd or pwd function changed the hierarchy result"
fi

deadline_repo="$TMP/embedded-python-deadline"
write_valid_repo "$deadline_repo"
deadline_checker="$TMP/check-hierarchy-deadline.sh"
cp "$CHECKER" "$deadline_checker"
/usr/bin/python3 -I -S - "$deadline_checker" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
timeout = "TOTAL_OPERATION_TIMEOUT_SECONDS=120"
if source.count(timeout) == 1:
    source = source.replace(timeout, "TOTAL_OPERATION_TIMEOUT_SECONDS=1")
elif timeout in source:
    raise SystemExit("hierarchy operation timeout seam is ambiguous")
imports = "import stat\nimport sys"
if source.count(imports) != 1:
    raise SystemExit("hierarchy embedded-Python import seam changed")
source = source.replace(imports, "import stat\nimport sys\nimport time")
entry = "def compare() -> tuple[tuple[str, ...], int, int, int]:\n"
if source.count(entry) != 1:
    raise SystemExit("hierarchy comparison entry seam changed")
source = source.replace(entry, entry + "    time.sleep(5)\n")
path.write_text(source, encoding="utf-8")
PY
CHECKER="$deadline_checker"
SECONDS=0
run_check_external_bound "$deadline_repo" --ci
deadline_elapsed=$SECONDS
if [ "$CHECK_STATUS" -eq 2 ] && [ "$deadline_elapsed" -le 2 ] \
    && grep -q 'operation deadline' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_available=false$' <<<"$CHECK_OUTPUT"; then
    pass "the whole-operation deadline terminates embedded Python"
else
    fail "embedded Python escaped the operation deadline after ${deadline_elapsed}s"
fi
CHECKER="$ROOT/scripts/check-hierarchy-sync.sh"

cleanup_failure_repo="$TMP/post-popen-cleanup"
write_valid_repo "$cleanup_failure_repo"
cleanup_failure_checker="$TMP/check-hierarchy-cleanup-failure.sh"
cleanup_failure_pid="$TMP/hierarchy-cleanup-leader.pid"
cp "$CHECKER" "$cleanup_failure_checker"
/usr/bin/python3 -I -S - "$cleanup_failure_checker" \
    "$cleanup_failure_pid" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
pid_path = sys.argv[2]
source = path.read_text(encoding="utf-8")
entry = "selector = selectors.DefaultSelector()"
replacement = f"""real_selector = selectors.DefaultSelector()
    with open({pid_path!r}, "w", encoding="ascii") as pid_file:
        pid_file.write(str(process.pid))
    class FailingCloseSelector:
        def __init__(self, delegate):
            self.delegate = delegate

        def __getattr__(self, name):
            return getattr(self.delegate, name)

        def close(self):
            self.delegate.close()
            raise RuntimeError("controlled selector close failure")

    selector = FailingCloseSelector(real_selector)"""
if source.count(entry) != 1:
    raise SystemExit("hierarchy selector seam changed")
path.write_text(source.replace(entry, replacement), encoding="utf-8")
PY
CHECKER="$cleanup_failure_checker"
run_check_external_bound "$cleanup_failure_repo" --ci
cleanup_failure_leader=""
if ! cleanup_failure_leader=$(cat "$cleanup_failure_pid" 2>/dev/null); then :; fi
cleanup_failure_leader_active=false
if [[ "$cleanup_failure_leader" =~ ^[0-9]+$ ]]; then
    cleanup_failure_state=""
    if ! cleanup_failure_state=$(
        /bin/ps -o stat= -p "$cleanup_failure_leader" 2>/dev/null
    ); then :; fi
    case "$cleanup_failure_state" in
        ""|*Z*) ;;
        *) cleanup_failure_leader_active=true ;;
    esac
fi
if [ "$CHECK_STATUS" -eq 2 ] \
    && grep -q 'controlled selector close failure' <<<"$CHECK_OUTPUT" \
    && [[ "$cleanup_failure_leader" =~ ^[0-9]+$ ]] \
    && [ "$cleanup_failure_leader_active" = false ]; then
    pass "post-Popen cleanup failure still terminates and reaps embedded Python"
else
    fail "post-Popen cleanup failure bypassed hierarchy process cleanup"
fi
CHECKER="$ROOT/scripts/check-hierarchy-sync.sh"

oversized_input="$TMP/oversized-input"
write_valid_repo "$oversized_input"
python3 - "$oversized_input/provisioning/Myrmidons/agents/hierarchy/task-agent.md" <<'PY'
from pathlib import Path
import sys

with Path(sys.argv[1]).open("a", encoding="utf-8") as output:
    output.write("x" * (1024 * 1024 + 1))
PY
run_check "$oversized_input" --ci
assert_unavailable "an oversized hierarchy definition is unavailable"

oversized_inventory="$TMP/oversized-inventory"
write_valid_repo "$oversized_inventory"
for entry in $(seq 1 4100); do
    : > "$oversized_inventory/provisioning/Myrmidons/agents/hierarchy/noise-$entry.txt"
done
run_check "$oversized_inventory" --ci
assert_unavailable "an oversized hierarchy directory inventory is unavailable"

bounded_valid_repo="$TMP/bounded-valid-repo"
write_valid_repo "$bounded_valid_repo"
canonical_checker="$CHECKER"

aggregate_checker="$TMP/check-hierarchy-aggregate-limit.sh"
checker_with_limit "$aggregate_checker" \
    'MAX_TOTAL_INPUT_BYTES = 16 * 1024 * 1024' \
    'MAX_TOTAL_INPUT_BYTES = 512'
CHECKER="$aggregate_checker"
run_check "$bounded_valid_repo" --ci
assert_unavailable "the aggregate hierarchy input limit is enforced"

count_checker="$TMP/check-hierarchy-file-count-limit.sh"
CHECKER="$canonical_checker"
checker_with_limit "$count_checker" \
    'MAX_INPUT_FILES = 512' 'MAX_INPUT_FILES = 5'
CHECKER="$count_checker"
run_check "$bounded_valid_repo" --ci
assert_unavailable "the hierarchy file-count limit is enforced"

report_checker="$TMP/check-hierarchy-report-limit.sh"
CHECKER="$canonical_checker"
checker_with_limit "$report_checker" \
    'MAX_REPORT_BYTES = 1024 * 1024' 'MAX_REPORT_BYTES = 1'
CHECKER="$report_checker"
run_check "$bounded_valid_repo" --ci
assert_unavailable "the hierarchy report limit is enforced"
CHECKER="$canonical_checker"

invalid_utf8="$TMP/invalid-utf8"
write_valid_repo "$invalid_utf8"
printf '\377' >> \
    "$invalid_utf8/provisioning/Myrmidons/agents/hierarchy/task-agent.md"
run_check "$invalid_utf8" --ci
assert_unavailable "invalid UTF-8 in a required definition is unavailable"

unterminated="$TMP/unterminated-frontmatter"
write_valid_repo "$unterminated"
python3 - "$unterminated/research/Odyssey/.claude/agents/test-review-specialist.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
del lines[lines.index("---", 1)]
path.write_text("\n".join(lines) + "\n")
PY
run_check "$unterminated" --ci
assert_drift \
    "malformed instruction frontmatter reports drift" \
    "unterminated frontmatter"

duplicate_runtime="$TMP/duplicate-runtime"
write_valid_repo "$duplicate_runtime"
write_runtime_role \
    "$duplicate_runtime/provisioning/Myrmidons/agents/hierarchy/duplicate.md" \
    task-agent
run_check "$duplicate_runtime" --ci
assert_drift \
    "a duplicate runtime role name fails" \
    "duplicate Myrmidons runtime frontmatter name task-agent"

zero_parser="$TMP/zero-parser"
write_valid_repo "$zero_parser"
mkdir -p "$zero_parser/bin"
cat > "$zero_parser/bin/python3" <<'EOF'
#!/usr/bin/env bash
: > "${HIERARCHY_FAILURE_MARKER:?}"
printf '%s\n' 'hierarchy_available=true' 'hierarchy_drift=false'
exit 0
EOF
chmod +x "$zero_parser/bin/python3"
HIERARCHY_FAILURE_MARKER="$zero_parser/python-invoked"
export HIERARCHY_FAILURE_MARKER
run_check_with_path "$zero_parser" "$zero_parser/bin" --ci
unset HIERARCHY_FAILURE_MARKER
if [ "$CHECK_STATUS" -eq 0 ] \
    && [ ! -e "$zero_parser/python-invoked" ] \
    && grep -q '^hierarchy_available=true$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT"; then
    pass "a zero-exit PATH interpreter cannot forge a result"
else
    fail "a zero-exit PATH interpreter affected the trusted result"
fi

one_parser="$TMP/one-parser"
write_valid_repo "$one_parser"
mkdir -p "$one_parser/bin"
cat > "$one_parser/bin/python3" <<'EOF'
#!/usr/bin/env bash
: > "${HIERARCHY_FAILURE_MARKER:?}"
printf '%s\n' \
    'hierarchy_receipt={"result":"drift","schema":"odysseus.hierarchy-check","version":1}'
exit 1
EOF
chmod +x "$one_parser/bin/python3"
HIERARCHY_FAILURE_MARKER="$one_parser/python-invoked"
export HIERARCHY_FAILURE_MARKER
run_check_with_path "$one_parser" "$one_parser/bin" --ci
unset HIERARCHY_FAILURE_MARKER
if [ "$CHECK_STATUS" -eq 0 ] \
    && [ ! -e "$one_parser/python-invoked" ] \
    && grep -q '^hierarchy_available=true$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT"; then
    pass "a failing PATH interpreter cannot suppress the trusted result"
else
    fail "a failing PATH interpreter affected the trusted result"
fi

invalid_receipt="$TMP/invalid-receipt"
write_valid_repo "$invalid_receipt"
mkdir -p "$invalid_receipt/bin"
cat > "$invalid_receipt/bin/python3" <<'EOF'
#!/usr/bin/env bash
: > "${HIERARCHY_FAILURE_MARKER:?}"
printf '%s\n' 'hierarchy_receipt={"result":"clean"}'
exit 0
EOF
chmod +x "$invalid_receipt/bin/python3"
HIERARCHY_FAILURE_MARKER="$invalid_receipt/python-invoked"
export HIERARCHY_FAILURE_MARKER
run_check_with_path "$invalid_receipt" "$invalid_receipt/bin" --ci
unset HIERARCHY_FAILURE_MARKER
if [ "$CHECK_STATUS" -eq 0 ] \
    && [ ! -e "$invalid_receipt/python-invoked" ] \
    && grep -q '^hierarchy_available=true$' <<<"$CHECK_OUTPUT" \
    && grep -q '^hierarchy_drift=false$' <<<"$CHECK_OUTPUT"; then
    pass "an invalid PATH receipt cannot replace trusted completion evidence"
else
    fail "an invalid PATH receipt affected the trusted result"
fi

info "the suite trap preserves fatal status, incomplete execution, and cleanup failure"
set +e
ODYSSEUS_TEST_HARNESS_PROBE=fatal \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$BASH" "$SCRIPT_DIR/test-hierarchy-sync.sh" \
    > "$TMP/harness-fatal.out" 2>&1
harness_fatal_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=incomplete \
    "$BASH" "$SCRIPT_DIR/test-hierarchy-sync.sh" \
    > "$TMP/harness-incomplete.out" 2>&1
harness_incomplete_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=complete \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$BASH" "$SCRIPT_DIR/test-hierarchy-sync.sh" \
    > "$TMP/harness-cleanup.out" 2>&1
harness_cleanup_status=$?
set -e
if [ "$harness_fatal_status" -eq 73 ] \
    && [ "$harness_incomplete_status" -eq 78 ] \
    && [ "$harness_cleanup_status" -eq 79 ] \
    && grep -Fq 'did not reach its completion marker' \
        "$TMP/harness-incomplete.out" \
    && grep -Fq 'controlled hierarchy cleanup failure' \
        "$TMP/harness-fatal.out" \
    && grep -Fq 'controlled hierarchy cleanup failure' \
        "$TMP/harness-cleanup.out"; then
    pass "only a completed hierarchy suite with successful cleanup can exit zero"
else
    printf '%s\n' \
        "fatal=$harness_fatal_status incomplete=$harness_incomplete_status cleanup=$harness_cleanup_status" >&2
    fail "the hierarchy suite trap converted incomplete or cleanup-failed work to success"
fi

summary
suite_completed=1
exit_code
