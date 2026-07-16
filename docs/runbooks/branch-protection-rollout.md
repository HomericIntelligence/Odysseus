# Branch Protection Rollout Runbook

How to add a new repo to the `homeric-main-baseline` ruleset, or re-apply the
ruleset after a change.

The repository-owned ruleset variants include the approved `main` merge queue:
squash, `ALLGREEN`, maximum 10 queue builds, maximum 5 merged entries per
group, minimum 1 entry, a 5-minute minimum wait, and a 60-minute check timeout.
Queue activation is deliberately separate from landing workflow support.

The live rulesets in each target repository are authoritative. For an existing
`homeric-main-baseline`, the apply script reads the live object and changes only
its enforcement mode and single `merge_queue` rule. It refuses an update if its
preservation check finds any change to required contexts, conditions, bypass
actors, or unrelated rules. The JSON files in `configs/github/` supply only the
approved queue rule and requested enforcement mode for this update path; their
complete fixed payload never replaces repository-specific live policy or
bootstraps a missing ruleset.

Argus is independently authoritative and uses a dedicated
`homeric-main-merge-queue` ruleset. Follow
[Argus issue #550](https://github.com/HomericIntelligence/Argus/issues/550) and
its [replacement implementation PR #551](https://github.com/HomericIntelligence/Argus/pull/551).
The generic script permits an Argus dry-run for preservation evidence, but
refuses live Argus activation.

## Prerequisites

- `gh` CLI authenticated with org-admin scope
- Run all commands from the Odysseus root directory

## Adding a new repo

1. In the new repo, create `.github/workflows/_required.yml` using
   `research/Scylla/.github/workflows/_required.yml` as the reference.
   The workflow must be named `Required Checks` and have `name:` fields that
   match the contexts in `configs/github/canonical-checks.md`. There are
   **8 required contexts**; `_required.yml` also defines a 9th job
   (`forbid-suppressions`) that is intentionally NOT a required context.
   Each job must invoke a real validator for that repo's stack.

2. Open a PR, verify all 8 required contexts appear in the PR checks UI once CI
   runs, then merge.

3. Bootstrap `homeric-main-baseline` from a ruleset definition owned and tested
   by the new repository. The central apply script intentionally refuses to
   create a missing ruleset from Odysseus's fixed context list.

4. After the repository-owned baseline exists, generate the scoped evaluate
   payload without mutation:

   ```bash
   ./tools/github/apply-repo-rulesets.sh \
     --evaluate --repos <NewRepo> --dry-run
   ```

   A target scope is mandatory. Use `--repos` for staged rollout; `--all` is an
   explicit fleet-wide acknowledgement and still refuses Argus.

5. Apply evaluate mode, observe it for one PR cycle, then flip to active:

   ```bash
   ./tools/github/apply-repo-rulesets.sh --evaluate --repos <NewRepo>
   ./tools/github/apply-repo-rulesets.sh --active --repos <NewRepo>
   ```

## Activating the Odysseus merge queue after issue #386

Do not apply the queue while the readiness PR is open. After that PR merges:

1. Confirm all 11 required contexts completed successfully on the merge commit.
2. Run the offline contract again:

   ```bash
   just test-merge-queue-readiness
   ```

3. Generate the exact Odysseus update payload without mutating GitHub. Confirm
   it contains all live required contexts and differs only in enforcement and
   the approved queue rule:

   ```bash
   ./tools/github/apply-repo-rulesets.sh \
     --active --repos Odysseus --dry-run
   ```

4. Activate only the Odysseus repository ruleset:

   ```bash
   ./tools/github/apply-repo-rulesets.sh --active --repos Odysseus
   ```

5. Queue one low-risk pull request with `gh pr merge --auto --squash`. Confirm
   GitHub creates a merge group, all 11 required contexts report on that group,
   and the pull request squash-merges through the queue.

This runbook records the activation requirement; the issue #386 implementation
PR must not run step 4 or otherwise mutate the live ruleset.

## Re-applying the ruleset to all repos

```bash
# Evaluate mode first (shadow enforcement — reports but doesn't block).
# Name only repositories whose own rollout has approved the generic path.
# Argus is rejected here because its issue #550 path owns a dedicated ruleset.
./tools/github/apply-repo-rulesets.sh --evaluate --repos <RepoA,RepoB>

# Check evaluate results
gh api "repos/HomericIntelligence/<repo>/rulesets/rule-suites?ref=refs/heads/main" \
  --jq '.[] | {result, evaluation_result, pushed_at}' | head -20

# Flip to active when evaluate shows all-pass
./tools/github/apply-repo-rulesets.sh --active --repos <RepoA,RepoB>
```

## Verify a repo's ruleset state

```bash
gh api repos/HomericIntelligence/<repo>/rulesets \
  --jq '.[] | select(.name=="homeric-main-baseline") | {id, enforcement}'

# Full detail (contexts list)
ID=$(gh api repos/HomericIntelligence/<repo>/rulesets \
  --jq '.[] | select(.name=="homeric-main-baseline") | .id')
gh api repos/HomericIntelligence/<repo>/rulesets/$ID \
  --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'
```

## Bypass actor (admin merge)

The ruleset has a `RepositoryRole` bypass actor (id 5 = admin) in `pull_request`
mode. Admins can bypass the ruleset to merge a PR that would otherwise be blocked
by the old context list during a ruleset migration. Use sparingly.

## Rollback

Re-applying evaluate mode is the scoped rollback for a repository whose queue
uses `homeric-main-baseline`:

```bash
./tools/github/apply-repo-rulesets.sh --evaluate --repos <repo>
```

For Argus, disable only its dedicated `homeric-main-merge-queue` ruleset as
documented in Argus #550/#551. Do not edit either required-check ruleset.

> Note: `org-ruleset.json` is not applied on the current GitHub plan —
> `gh api orgs/HomericIntelligence/rulesets` returns 404 / requires `admin:org`.
> Per-repo rulesets (`repos/<org>/<repo>/rulesets`) are the enforcing path.

To remove the ruleset entirely from a single repo:

```bash
ID=$(gh api repos/HomericIntelligence/<repo>/rulesets \
  --jq '.[] | select(.name=="homeric-main-baseline") | .id')
gh api -X DELETE repos/HomericIntelligence/<repo>/rulesets/$ID
```
