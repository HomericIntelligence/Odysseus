# Branch Protection Rollout Runbook

How to add a new repo to the `homeric-main-baseline` ruleset, or re-apply the
ruleset after a change.

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

3. Apply the ruleset to the new repo in shadow (evaluate) mode first:
   ```bash
   ./tools/github/apply-repo-rulesets.sh --evaluate --repos <NewRepo>
   ```
   (The bare invocation now applies the canonical `repo-ruleset.json`, which is
   `active`; pass `--evaluate` for the shadow pass.)

4. Observe evaluate mode for one PR cycle, then flip to active:
   ```bash
   ./tools/github/apply-repo-rulesets.sh --active --repos <NewRepo>
   ```

## Re-applying the ruleset to all repos

```bash
# Evaluate mode first (shadow enforcement — reports but doesn't block).
# NOTE: the bare invocation applies the canonical repo-ruleset.json, which is
# now "active"; use --evaluate explicitly for the shadow pass.
./tools/github/apply-repo-rulesets.sh --evaluate

# Check evaluate results
gh api "repos/HomericIntelligence/<repo>/rulesets/rule-suites?ref=refs/heads/main" \
  --jq '.[] | {result, evaluation_result, pushed_at}' | head -20

# Flip to active when evaluate shows all-pass
./tools/github/apply-repo-rulesets.sh --active
```

## Merge queue rollout

After the repository's required workflows handle the `merge_group` event and
the implementation PR passes review, preview the queue rule without changing
GitHub:

```bash
just merge-queue-rulesets-dry-run
```

The patcher reads each live `homeric-main-baseline` ruleset and preserves its
repository-specific checks and unrelated rules. It adds or replaces only the
`merge_queue` rule with the approved policy: `SQUASH`, `HEADGREEN`, maximum 10
queue builds, maximum 5 merged entries per group, minimum 1 entry, a 5-minute
minimum wait, and a 180-minute check timeout (#475; supersedes the earlier
ALLGREEN/60-minute proposals). It discovers active non-fork repos
by default and supports `--repos RepoName` for a staged rollout.

Apply one repository in evaluate mode first:

```bash
just merge-queue-ruleset-evaluate <RepoName>
```

After the smoke check and strict PR review pass, activate the queue rule across
the approved set:

```bash
just merge-queue-rulesets-activate
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

Re-applying evaluate mode is instant and safe:
```bash
./tools/github/apply-repo-rulesets.sh --evaluate   # or: --repos <repo>
```

> Note: `org-ruleset.json` is not applied on the current GitHub plan —
> `gh api orgs/HomericIntelligence/rulesets` returns 404 / requires `admin:org`.
> Per-repo rulesets (`repos/<org>/<repo>/rulesets`) are the enforcing path.

To remove the ruleset entirely from a single repo:
```bash
ID=$(gh api repos/HomericIntelligence/<repo>/rulesets \
  --jq '.[] | select(.name=="homeric-main-baseline") | .id')
gh api -X DELETE repos/HomericIntelligence/<repo>/rulesets/$ID
```
