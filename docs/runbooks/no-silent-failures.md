# Runbook: No Silent Failures

## The rule

Source-controlled shell, YAML, Dockerfile, justfile, and HCL files in this
repository **must not** contain:

1. `|| true` (and any `|| :` / `|| exit 0` equivalent at end of a command)
2. `continue-on-error: true` in GitHub Actions workflows

The `forbid-suppressions` job in `.github/workflows/_required.yml` (and the
matching pre-commit hook in `.pre-commit-config.yaml`) enforce this on every
PR. Both run a simple grep — no allowlist, no escape hatch — because every
historical exception in this codebase eventually masked a real bug.

## Why

The pattern `cmd || true` discards `cmd`'s exit code. Under `set -euo pipefail`
or any CI driver that treats non-zero as failure, this silently converts a real
problem into apparent success. Recorded incidents:

- **AchaeanFleet 2026-04**: `RUN goose --version || true` in three vessel
  Dockerfiles concealed broken arm64 binaries for an entire QEMU release.
  Documented in skill `ci-cd-achaean-fleet-ci-cascade-patterns` (v2.0.0,
  verified-ci).
- **AchaeanFleet 2026-04**: `continue-on-error: true` on the CHANGELOG push
  step hid a branch-protection rejection. The workflow ran green for weeks
  while CHANGELOG never updated.

## How to refactor

Every existing `|| true` falls into one of five buckets. Identify the bucket,
apply the corresponding fix:

### Bucket A — Masks a real failure → fix the root cause, then delete `|| true`

Example:
```bash
# WRONG: the whole point of doctor is to fail if apt-install fails
apt_install git && check_pass "git installed" || true
```
```bash
# RIGHT: explicit branches for success and failure
if apt_install git; then
    check_pass "git installed"
else
    check_fail "git install failed"
fi
```

### Bucket B — Best-effort cleanup or teardown → explicit `if`-guard

Example:
```bash
# WRONG: discards every error from podman, including unexpected ones
xargs -r podman rm -f 2>/dev/null || true
```
```bash
# RIGHT: log unexpected failures but do not abort teardown
if ! xargs -r podman rm -f 2>/dev/null; then
    echo "warn: teardown encountered errors (idempotent)" >&2
fi
```

For trap handlers that kill PIDs, guard with `kill -0`:
```bash
for pid in "${_BG_PIDS[@]}"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || echo "warn: kill failed for $pid" >&2
    fi
done
```

### Bucket C — `((counter++)) || true` under `set -e`

The `||` is only needed because `((x++))` evaluates to the *pre*-increment
value, which is `0` (falsy) on the first call. Sidestep the idiom entirely:

```bash
# WRONG
((PASS++)) || true
```
```bash
# RIGHT
PASS=$((PASS + 1))
```

### Bucket D — Pipeline-tail suppression (`grep ... || true`)

Under `set -o pipefail`, a `grep` that finds no matches returns `1` and the
whole pipeline fails. The fix is to capture the value with an explicit guard,
not to swallow the exit code:

```bash
# WRONG
version=$("$@" 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true)
```
```bash
# RIGHT: separate the failing step, give it an explicit fallback
if out=$("$@" 2>&1); then
    version=$(printf '%s\n' "$out" | grep -oP '\d+\.\d+[\.\d]*' | head -1 || printf '')
else
    version=''
fi
printf '%s' "$version"
```

For count-style queries where "no matches" means zero, use `grep -c`:
```bash
# WRONG
UNINIT=$(git submodule status | grep -c '^-' || true)
```
```bash
# RIGHT — grep -c always returns 0 if the input is non-empty:
UNINIT=$(git submodule status | grep -c '^-' || printf '0')
```
The trailing `|| printf '0'` is **not** `|| true` — it provides a real value
on the unmatched-no-input case. (Reviewers: this is allowed because the
fallback is a concrete value, not a discarded exit code.)

### Bucket E — `continue-on-error: true` in workflows

Always wrong. Fix the underlying step (e.g., bot opens PR + auto-merges
instead of pushing to a protected branch directly). See AchaeanFleet
changelog-workflow lessons in skill `ci-cd-achaean-fleet-ci-cascade-patterns`.

### Bucket F — Advisory `::warning::` annotation wrapping a tool's exit

```yaml
# WRONG — morally identical to continue-on-error: true: the CI step passes
# even when the tool found a real issue.
- run: |
    if ! pip-audit; then
        echo "::warning::pip-audit found vulnerabilities"
    fi
```

```yaml
# WRONG — same idea, single-line form
- run: gitleaks detect --source . || echo "::warning::gitleaks found potential issues"
```

```yaml
# WRONG — tool-level "report but don't fail" flags
- run: gitleaks detect --exit-code 0    # the --exit-code 0 is the suppression
- run: trivy fs --exit-code 0 .          # ditto
- run: bandit --exit-zero                # ditto
```

The `::warning::` workflow annotation displays a yellow banner in the GitHub
PR check view, but it **does not fail the step**. Wrapping a tool's failure
exit in `if ! tool; then echo "::warning::..."; fi` (or the single-line
`tool || echo "::warning::..."` variant) is functionally identical to
`continue-on-error: true`: the step passes, the underlying problem is
silently accepted, and over time real findings (CVEs, leaked secrets, format
diffs, broken benchmarks) accumulate in the codebase.

**Right fix:** make the tool fail-fast and **fix the underlying issue**.

```yaml
# RIGHT — tool runs in fail-fast mode; real findings block the PR.
- run: pip-audit                          # default: exit 1 on findings
- run: gitleaks detect --source .         # default: exit 1 on findings
- run: trivy fs --exit-code 1 .           # explicit fail-fast (overrides
                                          # any tool default of exit-code 0)
```

When the tool *legitimately* reports a finding that you can't fix in this
PR (e.g., an unpatched CVE in a transitive dep), the path forward is:

1. Open a tracked issue for the finding.
2. Add the specific finding to the tool's allowlist file (`.gitleaks.toml`,
   `pip-audit --ignore-vuln`, etc.) **with an inline comment naming the
   issue number and the planned fix date**.
3. Merge the allowlist update as a separate, small PR.

Never just paper over the finding with `|| echo "::warning::..."`.

**Acceptable `::warning::` uses** are extremely narrow:

- A *pre-flight* step that runs *before* a tool and advises on a deprecated
  config or upcoming migration (e.g., a notice that Node 18 will be removed
  next quarter). These do not gate a tool's exit code.
- Documentation-only annotations from a step that itself cannot fail.

If you have one of those cases, write the annotation to stdout as
`echo "WARN: ..."` instead — the regex `::warning::` in `.github/workflows/`
is forbidden by the `forbid-advisory-warnings` lint rule.

## What about legitimate-looking uses?

There aren't any. Every pattern that *seems* legitimate has an explicit
equivalent (see Bucket B/C/D above). The codebase will not preserve any
`|| true` — even cleanup paths get an explicit `if`-guard. This rule is
deliberately strict because the cost of a missed silent failure (broken
arm64 vessels for weeks, CHANGELOG never updating) is much higher than the
cost of writing three extra lines of bash.

## Diagnostic one-liners

Ad-hoc shell run interactively or in documentation may freely use `|| true` —
the lint guard scans only committed `*.sh`/`*.bash`/`*.yml`/`*.yaml`/`*.hcl`/
`Dockerfile*`/`justfile`/`Justfile` files. Markdown documentation (including
this runbook) is not scanned. Use the runbook's quoted examples as fenced
code in PR descriptions or issue comments when explaining the rule.

Inside the scanned files, the guard recognises `|| true` at any control-flow
boundary: end-of-line, before `#` (trailing comment), before `)` (closing
substitution or subshell), before `;`, before `&&` or `||`. Comment lines
(starting with optional whitespace then `#`) are exempt so that this runbook
can quote the idiom for teaching. The regex used is:

```
^(?!\s*#).*\|\|\s*true(\s*$|\s*[#);&|])
```

If you discover a control-flow boundary not covered by this regex, file a
follow-up and widen the pattern — the guard is meant to be inclusive.

## Adding new files

When you add a new shell script, YAML workflow, or Dockerfile:

1. Run `pre-commit run --all-files` locally before committing.
2. If the hook flags `|| true`, refactor per the bucket above. Do not bypass
   with `--no-verify`. Do not add a `# noqa` comment — the hook has no
   allowlist syntax.
3. If you believe the rule is wrong for your case, open an issue with the
   specific example and reviewer comment. Do not bypass.

## Operational lessons (from the 2026-05-10 ecosystem sweep)

### The first CI run after removing a suppression will fail. That is success.

When you refactor a `|| true` or `continue-on-error: true` out of a CI
workflow, the very next CI run will almost certainly fail — because the
underlying tool was reporting a real issue all along and the suppression
was hiding it. **This is the lint guard doing its job.**

Examples observed:

- Removing `clang-tidy ... || true` exposed a GCC↔clang cross-tooling issue
  (GCC-generated `compile_commands.json` contains GCC-only `-W` flags that
  clang-tidy errors on as `clang-diagnostic-unknown-warning-option`).
- Removing `continue-on-error: true` from `pip-audit`/`gitleaks` steps
  surfaced findings that had silently accumulated for weeks.
- Removing `mypy ... || true` exposed pre-existing type errors.

Diagnose the failure and **fix the root cause**. Never re-introduce the
suppression as a "temporary" workaround — there is no such thing.

### Update meta-tests that pin to the literal suppression syntax

Some test suites have regression-guard tests that assert on the *exact
string* of a known suppression mechanism — e.g.:

```python
def test_npm_audit_is_non_blocking():
    assert "continue-on-error: true" in workflow_step_text
```

When the silent-failures sweep replaces `continue-on-error: true` with an
in-script `if !` + `::warning::` wrapper (Bucket E refactor), these tests
fail even though the *property* they were checking is preserved.

**Fix the meta-test before running the sweep**, not after. Broaden the
assertion from syntax to property:

```python
def test_npm_audit_is_non_blocking():
    # Accept either form — the property is "audit findings do not fail the workflow"
    legacy = "continue-on-error: true" in step_text
    in_script_capture = (
        "|| AUDIT_EXIT=$?" in step_text
        and "AUDIT_EXIT:-0" in step_text
    )
    assert legacy or in_script_capture, "audit step must be non-blocking"
```

> **Note:** With the Bucket F clarification (above), even the
> in-script-capture form is now forbidden if it's morally an advisory
> warning. The test should be updated to assert the underlying tool runs
> fail-fast. The above example is preserved as a transitional pattern.

To find these tests before refactoring:

```bash
grep -rn "continue-on-error\|or-true\|::warning::" tests/ \
  --include="*.py" --include="*.sh" --include="*.bash"
```

### Lint guards must self-exempt

A pygrep hook or CI grep that catches a pattern *will catch itself* if the
hook's `entry:` literal, error message, or YAML metadata contains the
pattern. Symptoms:

- CI fails on a fresh PR with an error pointing at the hook's own
  `_required.yml` line.
- Pre-commit fires on the hook's own description.

Fix: exclude the workflow file containing the hook AND the runbook that
documents the pattern from the `files:` regex, OR scope the regex tightly
enough (e.g., negative-lookbehind on `^\s*#`) that comment-quoted examples
don't match. The current Odysseus hooks use both strategies; the CI job's
`scan_files` array explicitly skips `.github/workflows/_required.yml` and
`docs/runbooks/no-silent-failures.md`.

## See also

- Skill `ci-cd-achaean-fleet-ci-cascade-patterns` (v2.0.0, verified-ci):
  Level 8 documents the `goose --version || true` arm64 incident.
- Skill `bash-set-e-pipefail-grep-no-matches-trap` (v1.0.0, verified-ci):
  the canonical Bucket D refactor.
- Skill `bash-unbound-array-pipefail-crash` (v1.0.0, verified-ci): if
  removing `|| true` exposes an unbound-array crash, the fix is `local -a
  ARR=()`, not re-adding the suppression.
- Skill `pre-commit-hook-configuration` (v2.3.0, verified-ci): the
  `language: pygrep` pattern used by this repo's hook.
