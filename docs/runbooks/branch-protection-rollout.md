# Branch Protection and Merge Queue Rollout

This runbook converges the exact 16-repository first-party fleet to one
repository-owned `homeric-main-baseline`. It is an activation runbook, not
permission to mutate live GitHub state from the tooling PR.

## Authority and artifacts

`configs/github/fleet-ruleset-policy.json` is the only parameter authority.
`tools/github/render-fleet-ruleset.py` renders and checks the tracked active,
evaluate, and compatibility payloads. Regenerate them only through
`just repo-rulesets-render`. The former organization-wide `~ALL`
payload is retired because the organization contains excluded repositories.
The provenance catalog and the 16 live-captured fixtures under
`tests/fixtures/github/fleet-policy/` bind every first-party repository to its
captured default-branch SHA and exact GitHub readbacks. They expose current
extra-ruleset and classic-protection drift; synthetic fixtures separately prove
convergence to the rendered policy.

The [Odysseus #386 revision-2 activation ledger](https://github.com/HomericIntelligence/Odysseus/issues/386#issuecomment-5444607661)
is the canonical index of per-repository cutover issues. Do not copy that
ledger into a second manifest; record each repository's evidence on its indexed
activation issue.

The reconciler reads the complete repository-owned baseline and repository
settings from GitHub. It also paginates `includes_parents=true` rulesets,
fetches every ruleset detail, reads effective rules for the exact default
branch, and reads classic branch protection. Disabled extras are inventoried.
An inherited or additional active rule affecting the branch is an explicit
stop unless one exact repository-owned extras ruleset has a reviewed approval
file. A missing or duplicate baseline, unknown rule, incomplete response,
renamed baseline, wildcard or alternate scope, or non-repository owner also
fails before payload derivation. The tool never creates a missing baseline.

The candidate is the complete canonical baseline: `~DEFAULT_BRANCH`, no bypass
actors, signed commits, protected deletion, squash-only pull requests with
resolved conversations, linear/non-fast-forward history, a `HEADGREEN` queue
with 10 concurrent builds and a 180-minute timeout, and only
`required-checks-gate` as a required context.

Every target completes a read-only fleet preflight before the first write.
Durable operator-local snapshots contain the full ruleset response, writable
repository settings, the effective/inherited/extra protection inventory, and
the full classic-protection response when present. For an approved extras
ruleset, the snapshots also contain the exact restore payload and the exact
disabled payload. Immediately before each repository transaction, the tool
rechecks the evidence-bound main SHA and all resource preimages. Immediately
before the extras write, it rechecks the complete midpoint state. This state
includes the canonical baseline, repository settings, complete ruleset list,
effective rules, classic protection, and the approved extras ruleset. A changed
precondition aborts without overwriting the new state. The tool compensates any
earlier completed repository in reverse order.

The transaction writes only a drifted baseline and only the seven governed
repository settings, with independent exact readback after each request. When
an approval file identifies one active extras ruleset, the transaction changes
only its enforcement from `active` to `disabled`. It records the complete
preimage and verifies the exact disabled readback before it continues.
Classic protection is observable drift: it is deleted only after the
equivalent active ruleset and the full classic restore fingerprint are read
back again immediately before deletion. Status checks returned with a null App
binding are restored as explicit `app_id: -1` (any App), avoiding automatic
provider selection. Deletion must be verified by an independent 404 readback.

Failed, ambiguous, or mismatched writes, HUP/INT/TERM/PIPE, and any unexpected
nonzero exit trigger one guarded classified rollback from durable preimages. A
resource is restored only when its current state still equals the requested
state; an unrelated third state is preserved for operator recovery. Every
restore has an independent exact readback, including when the rollback request
itself returns an ambiguous error. `UNCERTAIN MUTATION` is a fleet-wide stop
condition. GitHub does not provide compare-and-swap semantics for these
ruleset, repository, or branch-protection mutations, so this classification
cannot close the interval between the last GET and its following write. The
single-writer prerequisite below is therefore part of the safety boundary,
not merely an operational preference.

Dry-run output contains canonical `PROTECTION-INVENTORY`, `DIGEST`, and `DRIFT`
records. Set-like arrays are normalized, so API ordering does not change the
preview. Exact current state prints `NO-DRIFT` and issues no mutation.

## Prerequisites

- `gh` authenticated with repository-administration scope
- An operator-declared exclusive governance-writer window is active for every
  target repository. Pause ruleset/settings bots, other rollout sessions, and
  manual branch-protection edits until the final fleet readback completes.
  Without this cooperative lease, a same-resource change in the GET-to-write
  interval can be lost despite the immediate precondition read and guarded
  rollback; stop and classify the run as uncertain if exclusivity is broken.
- `jq`, `just`, and Python with PyYAML available (the pixi environment provides
  all three)
- commands run from the Odysseus repository root
- workflow changes merged to each target repository's default branch
- independent human review completed for changes under `.github/workflows/`
- Athena's protected `agent-contract-v1.0.0` tag published and every governed
  workflow calling its immutable commit SHA
- a per-repository activation issue containing the reviewed workflow inventory
  and fresh green health evidence for every protected-event, scheduled,
  required, publish, release, and deploy workflow; the inventory is owned by
  the activation issue rather than duplicated in this applicator
- successful `required-checks-gate` evidence, collected within 24 hours, on a
  pull-request SHA, a newly synthesized merge-group SHA, and the exact current
  default-branch SHA
- an operator assigned to inspect dry-run and read-back evidence

The evidence JSON has `schema_version: 1`, an ISO-8601 `observed_at`, and one
repository object per target. Each repository records `main_sha` and
`pull_request`, `merge_group`, and `main` proofs with `run_id`,
`attempt_number`, `sha`, the canonical run URL, and
`required_checks_gate: success`. The tool re-fetches each run attempt, all
paginated jobs, and its check suite. It requires the exact repository, event,
SHA, branch shape, workflow name/path, successful sole aggregate job and check
run from GitHub Actions App 15368, and exactly one referenced Athena reusable
workflow at the commit currently resolved by `agent-contract-v1.0.0`.
The release resolver requires the exact tag ref, a verified signed annotated
tag, a verified signed commit, and one active repository-owned tag ruleset with
no bypass that targets only `refs/tags/agent-contract-v*` and blocks update and
deletion. For each repository, it also reads the exact main tree and refuses a
missing `_required.yml` or any remaining `merge-queue-smoke.yml`. The complete
pull-request and merge-group job name/status/conclusion sets must be identical.

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
   Confirm smoke-only queue workflows are gone, `required-checks-gate` is the
   fail-closed aggregate, and every protected-event and publish/release/deploy
   workflow reports the protected Athena agent contract.

   Attach the reviewed inventory and fresh run URLs to that repository's
   activation issue. Include every protected-event, scheduled, required,
   publish, release, and deploy workflow, with event, conclusion, head SHA,
   attempt identity, and provider commit. This broader closure is mandatory
   operator evidence even though the applicator intentionally does not carry a
   second hand-maintained workflow manifest.

3. Generate a no-write candidate for one pilot repository:

   ```bash
   just repo-rulesets-preview <PilotRepo>
   ```

   If the activation issue explicitly approves retirement of one active
   repository-owned extras ruleset, create an operator-local JSON file:

   ```json
   {
     "schema_version": 1,
     "repositories": {
       "<PilotRepo>": {
         "id": 123456,
         "name": "reviewed-extras-ruleset"
       }
     }
   }
   ```

   Then run `just repo-rulesets-preview-approved-extra <PilotRepo>
   <approval.json>`. The file is a closed allowlist. Each entry must match one
   active repository-owned branch ruleset whose only included selector is
   `~DEFAULT_BRANCH` or the exact resolved default-branch ref. Wildcards,
   exclusions, inherited rulesets, alternate branches, unknown fields,
   approvals outside the target set, and two or more overlaps fail closed.

4. Preserve the canonical `PROTECTION-INVENTORY`, `DIGEST`, and `DRIFT`
   records. Compare every resource with the approved policy. Stop on any
   inherited or unapproved active extra rule, classic policy that cannot be
   restored, unknown field, unexpected digest, or unreviewed difference. For an
   approved extras rule, verify the exact identifier, name, repository owner,
   default-branch selector, empty exclusions, and enforcement-only transition.
   `NO-DRIFT` is a verified no-op, not permission to skip closure evidence.

5. Collect a fresh evidence JSON after all three GitHub runs finish. With
   explicit operator approval, activate only the reviewed pilot and use an
   operator-owned durable snapshot directory:

   ```bash
   just repo-rulesets-activate-repos \
     <PilotRepo> \
     <timestamped-gate-audit.json> \
     <durable-operator-path>/<PilotRepo>
   ```

   For the reviewed extras case, use `just
   repo-rulesets-activate-approved-extra <PilotRepo>
   <timestamped-gate-audit.json> <durable-operator-path>/<PilotRepo>
   <approval.json>`.

6. Preserve all snapshots and exact-postcondition output. Independently read
   back repository settings, the complete baseline, effective default-branch
   rules, and the absence of classic protection. For an approved extras rule,
   fetch the approved identifier independently. Verify its exact name, complete
   mutable payload, repository ownership, and `disabled` enforcement. Verify
   that none of its rules are effective. Run a representative queued PR and
   record the synthetic SHA and the sole required context. The queue is not
   validated until `required-checks-gate` succeeds and the PR merges with
   `SQUASH`.

7. Repeat the dry-run, review, activation, and read-back per repository. Use
   `--all` only as an explicit, separately approved fleet operation after the
   pilot succeeds. Run `just repo-rulesets-activate <evidence.json>` only for a
   separately approved exact-fleet activation. It fails unless the active
   non-fork organization inventory equals the canonical 16-repository list.

`--evaluate` changes the enforcement mode of the complete baseline. Updating an
already staged evaluate baseline remains supported, but active-to-evaluate
transitions fail before snapshot or PUT. Use `--evaluate --dry-run` (including
`just repo-rulesets-apply`) for a no-write preview against an active baseline.
Do not downgrade active protection merely to shadow-test the queue.

## Read-only verification

List every inherited/repository ruleset and fetch the complete baseline:

```bash
REPO=HomericIntelligence/<repo>
gh api --paginate "repos/${REPO}/rulesets?includes_parents=true&per_page=100" \
  --jq '.[] | {id, name, source, source_type, enforcement}'

ID=$(gh api "repos/${REPO}/rulesets?includes_parents=true" \
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
gh api --paginate "repos/${REPO}/rules/branches/main?per_page=100"
gh api "repos/${REPO}/branches/main/protection"
gh api "repos/${REPO}" \
  --jq '{allow_auto_merge, allow_merge_commit, allow_rebase_merge,
         allow_squash_merge, allow_update_branch, delete_branch_on_merge,
         web_commit_signoff_required}'
```

For an approved extras retirement, bind the values to the reviewed approval
file. Fetch the ruleset by its exact identifier. Compare the complete response
with the durable preimage after you change only `enforcement` to `disabled`:

```bash
EXTRA_ID=<approved-ruleset-id>
EXTRA_NAME=<approved-ruleset-name>
EXTRA_DISABLED=<durable-disabled-payload-path>
gh api "repos/${REPO}/rulesets/${EXTRA_ID}" | jq -e \
  --argjson id "${EXTRA_ID}" --arg name "${EXTRA_NAME}" \
  --arg source "${REPO}" \
  '.id == $id and .name == $name and .source == $source and
   .source_type == "Repository" and .enforcement == "disabled"'
gh api "repos/${REPO}/rulesets/${EXTRA_ID}" | jq \
  '{name, target, enforcement, bypass_actors, conditions, rules}' | \
  diff -u "${EXTRA_DISABLED}" -
gh api --paginate --slurp \
  "repos/${REPO}/rules/branches/main?per_page=100" | \
  jq --argjson id "${EXTRA_ID}" '[.[][] | select(.ruleset_id == $id)]'
```

The first command must show the approved identifier and name, repository
ownership, the exact reviewed selector and payload, and `disabled` enforcement.
The second command must return an empty array.

The classic-protection GET should return 404 after a successful migration. Any
other error, active effective rule from another ruleset, or repository-setting
mismatch is a failed activation.

## Rollback boundary

The apply script arms rollback before each resource request and keeps it armed
until the repository is recorded as complete. A verified rollback still
terminates the operation; rerun only after diagnosing the failure.
`UNCERTAIN MUTATION` is a fleet-wide stop condition: do not run another apply
and do not hand-edit protection. Preserve the durable ruleset, settings,
effective-policy, approved-extras full response, approved-extras restore
payload, approved-extras disabled payload, and classic-protection snapshots.
Use the restore payload only if the current extras state is the exact disabled
payload. Compare current state with both the preimage and requested state before
any reviewed manual recovery. Do not overwrite a third state created by another
actor. Restore classic protection first. Then, restore the extras ruleset,
repository settings, and baseline in reverse write order. Verify each restored
resource with an independent read.

Never disable, replace, or delete unrelated status, review, signature, or
bypass rules to recover from a queue problem. Retain the snapshot and the exact
API output as incident evidence until independent review confirms recovery.
