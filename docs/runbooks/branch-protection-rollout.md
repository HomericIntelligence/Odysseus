# Branch Protection Rollout Runbook

How to add a new repo to the `homeric-main-baseline` ruleset, or re-apply the
ruleset after a change.

## Prerequisites

- `gh` CLI authenticated with org-admin scope
- Run all commands from the Odysseus root directory

## Adding a new repo

1. In the new repo, create `.github/workflows/_required.yml` using
   `research/ProjectScylla/.github/workflows/_required.yml` as the reference.
   The workflow must be named `Required Checks` and have exactly 9 jobs whose
   `name:` fields match the contexts in `configs/github/canonical-checks.md`.
   Each job must invoke a real validator for that repo's stack.

2. Open a PR, verify all 9 contexts appear in the PR checks UI once CI runs,
   then merge.

3. Apply the ruleset to the new repo:
   ```bash
   ./tools/github/apply-repo-rulesets.sh --repos <NewRepo>
   ```

4. Observe evaluate mode for one PR cycle, then flip to active:
   ```bash
   ./tools/github/apply-repo-rulesets.sh --active --repos <NewRepo>
   ```

## Re-applying the ruleset to all repos

```bash
# Evaluate mode first (shadow enforcement — reports but doesn't block)
./tools/github/apply-repo-rulesets.sh

# Check evaluate results
gh api "repos/HomericIntelligence/<repo>/rulesets/rule-suites?ref=refs/heads/main" \
  --jq '.[] | {result, evaluation_result, pushed_at}' | head -20

# Flip to active when evaluate shows all-pass
./tools/github/apply-repo-rulesets.sh --active
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
./tools/github/apply-repo-rulesets.sh   # reverts to evaluate
```

To remove the ruleset entirely from a single repo:
```bash
ID=$(gh api repos/HomericIntelligence/<repo>/rulesets \
  --jq '.[] | select(.name=="homeric-main-baseline") | .id')
gh api -X DELETE repos/HomericIntelligence/<repo>/rulesets/$ID
```
