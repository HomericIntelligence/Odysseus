# Branch Protection and Merge Queue Rollout

This runbook stages the `homeric-main-baseline` merge-queue rollout without
replacing repository-specific protection.

## Authority and artifacts

Live complete repository rulesets are authoritative. Always read the exact
repository-owned ruleset from GitHub before diagnosing or changing protection.
The files under `configs/github/` are an input and review artifact for approved
enforcement and merge-queue parameters; they are not a complete fleet-wide
replacement payload and can drift from live rules.

`tools/github/apply-repo-rulesets.sh` fails closed unless it finds exactly one
repository-owned `homeric-main-baseline` whose fetched detail response has
`target: branch` and the exact main-only scope
`conditions.ref_name.include == ["refs/heads/main"]` and
`conditions.ref_name.exclude == []`. Wildcards, renamed rulesets, alternate or
missing branches, malformed scope, and inherited rulesets are rejected before
the script derives a payload. It derives the candidate from the complete live
response and changes only:

- the requested enforcement mode; and
- one `merge_queue` rule, added or replaced with the reviewed parameters.

The script preserves required contexts, bypass actors, target conditions, and
all unrelated rules. It refuses incomplete required-status-check schemas,
ambiguous baselines, and missing baselines. It never bootstraps a repository
from a fixed generic context list.

Before every non-dry-run PUT, the script atomically saves the complete fetched
pre-state under `configs/github/backups/ruleset-mutations/` (or an explicit
`--snapshot-dir`). That ignored operator-local snapshot survives process exit.
After PUT, the script fetches the ruleset again and requires an exact match for
`name`, `target`, `enforcement`, `bypass_actors`, `conditions`, and every rule.
Any failed or ambiguous PUT, failed readback, mismatched postcondition, or
HUP/INT/TERM while the mutation is armed triggers rollback from the pre-state,
followed by an exact rollback readback. HUP/INT/TERM are ignored while rollback
and its readback run so recovery is protected from a second ordinary shell
interrupt as far as the shell permits. The operation aborts before processing
another repository. If rollback cannot be verified, it reports `UNCERTAIN
MUTATION` and retains the durable snapshot for operator recovery.

Argus is not activated through this generic path. Its 14 contexts span two
rulesets and its dedicated rollout is tracked by
[Argus #550](https://github.com/HomericIntelligence/Argus/issues/550) and
[replacement PR #552](https://github.com/HomericIntelligence/Argus/pull/552).

## Prerequisites

- `gh` authenticated with repository-administration scope
- `jq`, `just`, and Python with PyYAML available (the pixi environment provides
  all three)
- commands run from the Odysseus repository root
- workflow changes merged to each target repository's default branch
- independent human review completed for changes under `.github/workflows/`
- an operator assigned to inspect dry-run and read-back evidence

## New repository baseline

Create a complete repository-owned baseline through that repository's reviewed
policy process. Ensure its required contexts are already emitted on pull-request
branches before making them required. This script intentionally refuses to
create a missing baseline.

After the baseline exists, continue with the staged activation below.

## Staged activation

Do not mutate live rulesets from the implementation PR. Activation starts only
after the workflow/configuration PR is merged and its required checks have
completed on `main`.

1. Run the offline readiness and security gates:

   ```bash
   just test-merge-queue-readiness
   pixi run ci
   ```

2. Confirm every required workflow on `main` handles
   `merge_group: checks_requested`. Confirm its validation jobs are read-only;
   publishing permissions must remain limited to trusted push or tag jobs.

3. Generate a no-write candidate for one pilot repository:

   ```bash
   ./tools/github/apply-repo-rulesets.sh \
     --active --repos <PilotRepo> --dry-run
   ```

4. Compare the candidate with the complete live ruleset. Required contexts,
   bypass actors, conditions, and non-queue rules must be identical. Stop on
   any difference.

5. With explicit operator approval, activate only the pilot:

   ```bash
   ./tools/github/apply-repo-rulesets.sh \
     --active --repos <PilotRepo> \
     --snapshot-dir <durable-operator-path>/<PilotRepo>
   ```

6. Preserve the script's snapshot path and exact-postcondition output. Then
   independently read the ruleset back from GitHub and run one representative
   queued PR. Record the merge-group SHA and exact required-check results. The
   queue is not validated until the synthetic merge group reports every
   required context and merges with `SQUASH`.

7. Repeat the dry-run, review, activation, and read-back per repository. Use
   `--all` only as an explicit, separately approved fleet operation after the
   pilot succeeds. Fleet operations audit and skip Argus; complete its
   separately reviewed #550/#552 rollout through the Argus-owned path.

`--evaluate` changes the enforcement mode of the complete baseline. Updating an
already staged evaluate baseline remains supported, but active-to-evaluate
transitions fail before snapshot or PUT. Use `--evaluate --dry-run` (including
`just repo-rulesets-apply`) for a no-write preview against an active baseline.
Do not downgrade active protection merely to shadow-test the queue.

## Read-only verification

List repository-owned rulesets and fetch the complete baseline:

```bash
REPO=HomericIntelligence/<repo>
gh api "repos/${REPO}/rulesets?includes_parents=false" \
  --jq '.[] | {id, name, source, source_type, enforcement}'

ID=$(gh api "repos/${REPO}/rulesets?includes_parents=false" \
  --jq '.[] | select(.name=="homeric-main-baseline" and
                     .source_type=="Repository") | .id')
gh api "repos/${REPO}/rulesets/${ID}" \
  --jq '{name, enforcement, conditions, bypass_actors, rules}'
```

Verify the required contexts and queue rule from that complete response:

```bash
gh api "repos/${REPO}/rulesets/${ID}" \
  --jq '.rules[] | select(.type=="required_status_checks") |
        .parameters.required_status_checks[].context'
gh api "repos/${REPO}/rulesets/${ID}" \
  --jq '.rules[] | select(.type=="merge_queue")'
```

## Rollback boundary

The apply script automatically arms rollback before PUT and verifies rollback
after any ambiguous write or postcondition failure. A verified rollback still
terminates the operation; rerun only after diagnosing the failed mutation. An
`UNCERTAIN MUTATION` is a fleet-wide stop condition: do not run another apply,
and do not hand-edit protection. Use the reported durable pre-state snapshot to
construct the same writable projection (`name`, `target`, `enforcement`,
`bypass_actors`, `conditions`, and `rules`), restore it with an explicitly
reviewed PUT, and verify an exact readback.

Never disable, replace, or delete unrelated status, review, signature, or
bypass rules to recover from a queue problem. Retain the snapshot and the exact
API output as incident evidence until independent review confirms recovery.
