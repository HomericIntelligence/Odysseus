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

## Adding new files

When you add a new shell script, YAML workflow, or Dockerfile:

1. Run `pre-commit run --all-files` locally before committing.
2. If the hook flags `|| true`, refactor per the bucket above. Do not bypass
   with `--no-verify`. Do not add a `# noqa` comment — the hook has no
   allowlist syntax.
3. If you believe the rule is wrong for your case, open an issue with the
   specific example and reviewer comment. Do not bypass.

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
