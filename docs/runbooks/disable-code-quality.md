# Runbook: Review or Disable GitHub Code Quality

This runbook defines the evidence and approval boundary for changing GitHub Code
Quality settings. It does not assert current pricing, product status, API
availability, UI labels, or repository state. Those details can change without
a repository commit and must be read from current official GitHub documentation
and the live repository settings immediately before an operation.

Disabling Code Quality is a remote repository-setting change. Read-only audit is
safe; a disable, enable, or related policy change requires explicit operator
approval for each exact repository and setting delta.

## Scope

The default scope is the 16 canonical HomericIntelligence repositories:
Odysseus plus the 15 component repositories recorded in `.gitmodules`.
`modular-community` is not a component gitlink and is excluded unless the
current request separately names it and an operator approves its exact change.

Code Quality is distinct from CodeQL security scanning, Dependabot, secret
scanning, push protection, branch protection, and repository rulesets. Do not
change any of those adjacent controls under this runbook.

## Stop conditions

Stop without changing remote state when any of these conditions applies:

- the exact repository inventory or authenticated GitHub identity is unknown;
- current official documentation and live settings do not identify a supported
  control for the requested Code Quality setting;
- a read is reported as `unavailable`, incomplete, or otherwise ambiguous;
- the operator has not approved the exact repository and before/after delta;
- the requested action would alter an adjacent security or merge control; or
- a rollback route and per-repository post-change readback are unavailable.

An unavailable or ambiguous read is not evidence that the feature is disabled.
Do not substitute an old pricing date, historical API response, remembered UI
label, or checked-in screenshot for current product and live-state evidence.

## 1. Bind the canonical inventory

Record the immutable Odysseus commit and derive the component names from its
checked-in submodule metadata:

```bash
git rev-parse HEAD
git config --file .gitmodules --get-regexp 'submodule\..*\.url'
```

The result must contain 15 component repositories. Add Odysseus to obtain the
16-repository default scope. If the count or ownership is different, stop and
resolve the inventory before auditing or requesting approval.

The repository provides a read-only convenience probe:

```bash
just code-quality-audit
```

Treat its output as discovery evidence only. The probe normalizes any ambiguous
or failed field or endpoint read to `unavailable`; that value does not prove an
off state. Do not use `code-quality-audit-all` for this runbook unless the request
and approval separately expand scope beyond the canonical inventory.

## 2. Bind current GitHub behavior and live state

In the same operation window:

1. Consult current official GitHub documentation for Code Quality availability,
   billing, controls, and the supported read/write path for the repository's
   plan and visibility.
2. Read the exact repository's live Code Quality state through that supported
   path using the approved operator identity.
3. Record the timestamp, repository, authenticated actor, official-documentation
   reference, supported control, and unambiguous before-state.
4. Separately read the adjacent CodeQL, Dependabot, secret-scanning,
   push-protection, and ruleset state that must remain unchanged.

Do not assume that a previously observed REST path is still available or absent,
that a UI control has the same name or location, or that a past preview or
pricing schedule still applies.

## 3. Obtain approval for an exact delta

Prepare one row per repository and obtain explicit operator approval before any
write:

| Repository | Bound before-state | Requested after-state | Supported control | Adjacent controls preserved | Approval |
|---|---|---|---|---|---|
|  |  |  |  |  |  |

Approval for one repository does not authorize the next repository, an
organization-wide setting, `modular-community`, or any adjacent security gate.
If the operator approves a batch, the approval must enumerate every repository
and the same exact delta for each one.

## 4. Apply and verify one repository at a time

For each approved row:

1. Re-read the live before-state and stop if it differs from the approved row.
2. Use only the currently supported GitHub control identified in Step 2.
3. Change only the approved Code Quality setting.
4. Immediately read the setting back through the supported live path.
5. Re-read the adjacent security and ruleset controls and prove they are
   unchanged.
6. Record the actual result before proceeding to another repository.

A successful click or command exit is not completion without the post-state
readback. If a write or readback fails, stop the batch, preserve the truthful
result, and do not retry through an undocumented endpoint or different control.

## 5. Completion receipt

Completion requires, for every repository in the approved scope:

- immutable inventory and repository identity;
- current official-product reference and live before-state;
- explicit approval for the exact delta;
- the supported operation's actual result;
- an unambiguous post-state matching the approved outcome; and
- proof that adjacent security and merge controls did not change.

List any repository with missing or ambiguous evidence as incomplete. Do not
summarize partial coverage as an organization-wide result.

## Recovery or re-enable

Re-enabling Code Quality is a new remote-setting change, not an implied rollback
authority. Repeat the same current-documentation, live-readback, exact-scope,
approval, and post-state process. Restore only the bound prior setting; do not
add a configuration file or ruleset requirement unless that separate delta is
explicitly requested and approved.

## Local references

- `tools/probe-code-quality.sh` — read-only discovery probe; ambiguous results
  require an independent supported live readback
- `just code-quality-audit` — canonical-inventory probe
- `docs/runbooks/branch-protection-rollout.md` — separate ruleset boundary
- `configs/github/backups/branch-protection-pre-ruleset.json` — historical
  evidence only; never a current-state source
