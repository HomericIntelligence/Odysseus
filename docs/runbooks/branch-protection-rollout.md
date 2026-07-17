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
repository-owned `homeric-main-baseline`. It derives the candidate from that
complete live response and changes only:

- the requested enforcement mode; and
- one `merge_queue` rule, added or replaced with the reviewed parameters.

The script preserves required contexts, bypass actors, target conditions, and
all unrelated rules. It refuses incomplete required-status-check schemas,
ambiguous baselines, and missing baselines. It never bootstraps a repository
from a fixed generic context list.

Argus is not activated through this generic path. Its 14 contexts span two
rulesets and its dedicated rollout is tracked by
[Argus #550](https://github.com/HomericIntelligence/Argus/issues/550) and
[replacement PR #552](https://github.com/HomericIntelligence/Argus/pull/552).

## Prerequisites

- `gh` authenticated with repository-administration scope
- `jq` and `just` available
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
   ./tools/github/apply-repo-rulesets.sh --active --repos <PilotRepo>
   ```

6. Read the ruleset back from GitHub and run one representative queued PR.
   Record the merge-group SHA and exact required-check results. The queue is not
   validated until the synthetic merge group reports every required context and
   merges with `SQUASH`.

7. Repeat the dry-run, review, activation, and read-back per repository. Use
   `--all` only as an explicit, separately approved fleet operation after the
   pilot succeeds. Fleet operations audit and skip Argus; complete its
   separately reviewed #550/#552 rollout through the Argus-owned path.

`--evaluate` changes the enforcement mode of the complete baseline. Use it only
when that baseline is already intentionally in a staged evaluate state. Do not
downgrade an active protection baseline merely to shadow-test the queue.

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

Rollback is an operator action against the freshly read live ruleset. Preserve a
complete pre-change response before activation, modify only the queue rule or
enforcement field, and read the result back. Never disable, replace, or delete
unrelated status, review, signature, or bypass rules to recover from a queue
problem.
