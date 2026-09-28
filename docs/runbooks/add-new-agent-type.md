# Runbook: Add a New Containerized Agent Type

## Choose the Deployment Type

Use the main procedure only when the exact Myrmidons schema and approved
desired state select a Docker/container deployment that needs an AchaeanFleet
vessel. Do not create a vessel merely because an agent type is new.

For a `local` deployment, use the [Local Deployment Branch](#local-deployment-branch)
below. The AchaeanFleet worktree, container runtime, image build, and
AchaeanFleet component or integration-PR steps do not apply.

## Important: Submodule Layout (Accepted: ADR-007)

Per [ADR-007 — Replace Symlinks with Real Git Submodules](../adr/007-symlinks-over-submodules.md) (**Accepted**), every component directory referenced in this runbook (including `infrastructure/AchaeanFleet` and `provisioning/Myrmidons`) is a real git submodule (`git ls-files -s` reports mode `160000`). Use this workflow:

1. Treat the component worktrees inside Odysseus as read-only. Work on a
   feature branch in an isolated worktree of each owning component repository.
2. Let component CI and review finish before merging that component PR.
3. After explicit integration approval identifies the exact merged commits,
   update the corresponding gitlinks in a separate Odysseus integration PR.

An uninitialized submodule appears as an empty directory or a `-`-prefixed
entry in `git submodule status`; `just bootstrap` materializes it. A symlink is
not a valid current layout and is not repaired by assuming it points to a
branch.

## Prerequisites

- You have cloned the Odysseus repo with submodules (`just bootstrap`).
- You have isolated, feature-branch worktrees for Myrmidons and, for the
  container path only, AchaeanFleet, prepared from verified remote base
  commits.
- You have write access to those component repositories.
- For the container path, a working Podman or compatible container runtime is
  installed (ADR 001).
- Any live Agamemnon test is explicitly authorized and isolated from
  production desired state.

## Local Deployment Branch

For a local agent type, work only in the isolated Myrmidons worktree unless a
separately scoped change has another owner:

1. Create the template from the nearest current local-deployment example and
   validate every field against `schemas/agent-v1.schema.json`.
2. Keep the deployment discriminator explicit. Preserve the current program,
   `programArgs`, model, role, lane, and provider defaults unless the approved
   task expressly changes one; do not add image or vessel fields.
3. Run the Myrmidons repository's `just validate` and `just test` front doors.
4. Use only the pinned Agamemnon reconciler's documented plan/diff route. A
   live apply needs separate authority, isolation, exact-result readback, and
   guaranteed cleanup.
5. Deliver the Myrmidons PR through its own CI/CD and exact-head
   `$athena:pr-review`. After it merges, update only the Myrmidons gitlink in a
   separately approved Odysseus integration PR and repeat those exact-head
   gates.

Stop here for a local deployment. The remaining steps are the container-only
branch.

---

## Steps

### 1. Create the Dockerfile in AchaeanFleet

In the isolated AchaeanFleet worktree, create a new vessel directory:

```bash
cd /path/to/AchaeanFleet/vessels/
agent_name='replace-with-agent-name'
mkdir "$agent_name"
```

Create a `Dockerfile` in that directory. Follow the conventions in existing vessels:
- Base image should be a minimal, OCI-compatible image.
- The entrypoint should be the agent binary or script.
- Document required environment variables in a comment block at the top of the Dockerfile.
- Update AchaeanFleet's checked-in vessel/base routing and its tests so
  `just build-vessel <agent-name>` recognizes the new name.

### 2. Build the vessel image

From the AchaeanFleet root:

```bash
cd /path/to/AchaeanFleet
agent_name='replace-with-agent-name'
just build-vessel "$agent_name"
```

The current AchaeanFleet recipe tags a vessel as
`achaean-<agent-name>:latest`. Verify the build succeeded:

```bash
agent_name='replace-with-agent-name'
podman images | rg "achaean-${agent_name}"
```

### 3. Plan the Agamemnon Change

Do not launch a live agent from a hand-written payload. The pinned Agamemnon
OpenAPI document and reconciler are the interface authorities; a Myrmidons
description remains desired-state input, not proof of deployment. After Step 4,
use the reconciler's documented plan/diff route in
`control/Agamemnon/tools/reconciler/`. Apply only to an explicitly authorized
environment, verify the returned agent identity and convergence, and guarantee
cleanup of any sandbox agent created for the smoke test.

### 4. Add a YAML template to Myrmidons

In the isolated Myrmidons worktree, add a template for the new agent type:

```bash
cd /path/to/Myrmidons/agents/_templates/
```

Create `<agent-name>.yaml` from the closest existing template. Validate every
field against `schemas/agent-v1.schema.json`; do not copy field names from this
runbook. Keep the deployment type explicit and place Docker-specific image and
resource data under the schema's Docker deployment object.

### 5. Validate the Myrmidons Dataset

From the Myrmidons root, use its checked-in task front door:

```bash
just validate
just test
```

Mnemosyne is a knowledge backend and has no agent-type marketplace. Do not add
an agent definition there. If the new agent also needs a genuinely reusable,
user-invoked workflow, propose a discriminating skill in Athena as a separate
change; most agent types need no new skill.

### 6. Open the Component Pull Requests

Commit and push feature branches, never component default branches directly.
For AchaeanFleet:

```bash
cd /path/to/AchaeanFleet
agent_name='replace-with-agent-name'
issue_number='replace-with-issue-number'
git add "vessels/${agent_name}/"
git commit -m "feat: add ${agent_name} vessel"
git push -u origin "${issue_number}-add-${agent_name}-vessel"
gh pr create --title "feat: add ${agent_name} vessel"
```

For Myrmidons:

```bash
cd /path/to/Myrmidons
agent_name='replace-with-agent-name'
issue_number='replace-with-issue-number'
git add "agents/_templates/${agent_name}.yaml"
git commit -m "feat: add ${agent_name} template"
git push -u origin "${issue_number}-add-${agent_name}-template"
gh pr create --title "feat: add ${agent_name} template"
```

Each PR must pass `$athena:pr-review` and its repository-owned CI/CD contract
before merge. If an Athena skill was independently justified, deliver it
through its own Athena PR; do not couple it to a Mnemosyne marketplace change.

### 7. Update Odysseus Gitlinks After Approval

After both component PRs merge, obtain explicit integration approval and bind
their exact merged SHAs. In an isolated Odysseus integration branch, check out
those commits in the component worktrees and stage the gitlink paths:

```bash
agent_name='replace-with-agent-name'
issue_number='replace-with-issue-number'
odysseus_base_sha='replace-with-verified-origin-main-sha'
achaean_fleet_sha='replace-with-merged-achaean-fleet-sha'
myrmidons_sha='replace-with-merged-myrmidons-sha'
git -C /path/to/Odysseus fetch origin main
git -C /path/to/Odysseus rev-parse --verify 'origin/main^{commit}'
git -C /path/to/Odysseus worktree add \
  -b "${issue_number}-integrate-${agent_name}" \
  "/path/to/worktrees/Odysseus-${issue_number}" \
  "$odysseus_base_sha"
cd "/path/to/worktrees/Odysseus-${issue_number}"
git submodule update --init infrastructure/AchaeanFleet provisioning/Myrmidons

git -C infrastructure/AchaeanFleet fetch origin
git -C infrastructure/AchaeanFleet rev-parse --verify \
  "${achaean_fleet_sha}^{commit}"
git -C infrastructure/AchaeanFleet checkout --detach \
  "$achaean_fleet_sha"

git -C provisioning/Myrmidons fetch origin
git -C provisioning/Myrmidons rev-parse --verify \
  "${myrmidons_sha}^{commit}"
git -C provisioning/Myrmidons checkout --detach "$myrmidons_sha"

git add infrastructure/AchaeanFleet provisioning/Myrmidons
git commit -m "chore: integrate ${agent_name} agent type"
git push -u origin "${issue_number}-integrate-${agent_name}"
gh pr create --title "chore: integrate ${agent_name} agent type"
```

The commit SHAs live in the gitlink entries, not `.gitmodules`; do not edit
`.gitmodules` unless a component path or remote URL itself changes.

The Odysseus integration PR is a separate pull request and must independently
pass every live required CI/CD check plus terminal `$athena:pr-review` `GO` on
its exact current head before merge. Do not treat the component-PR results as
evidence for the changed integration tree.

---

## Verification Checklist

- [ ] `Dockerfile` created in `infrastructure/AchaeanFleet/vessels/<agent-name>/`
- [ ] `just build-vessel <agent-name>` succeeds
- [ ] AchaeanFleet routing/tests recognize the vessel and its actual image tag
- [ ] Template added to `provisioning/Myrmidons/agents/_templates/<agent-name>.yaml`
- [ ] Myrmidons schema, reference, and dataset tests pass
- [ ] An authorized Agamemnon plan shows the intended change
- [ ] Any authorized sandbox apply converges and cleanup is verified
- [ ] Component PR review and CI pass
- [ ] Exact gitlinks are updated only in a separately approved integration PR
- [ ] The exact integration-PR head passes its own Athena review and required
      CI/CD checks before merge
