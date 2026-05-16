# Runbook: Add a New Agent Type to the HomericIntelligence Ecosystem

## Important: Submodule Layout (Accepted: ADR-007)

Per [ADR-007 — Replace Symlinks with Real Git Submodules](../adr/007-symlinks-over-submodules.md) (**Accepted**), every subdirectory referenced in this runbook (`infrastructure/AchaeanFleet`, `provisioning/Myrmidons`, `shared/ProjectMnemosyne`, etc.) is now a real git submodule (`git ls-files -s` reports mode `160000`). When making changes to these repos, the recommended workflow is:

1. `cd` into the submodule path inside the Odysseus checkout (e.g. `cd infrastructure/AchaeanFleet`) — it has its own `.git` link and acts as a normal repo clone of the submodule's branch.
2. Make commits and push to the submodule's GitHub remote.
3. Return to the Odysseus root and `git add` the submodule path to bump the recorded gitlink SHA.
4. Commit and push the submodule SHA bump in Odysseus.

> Older versions of this runbook described a symlink-based layout (the
> situation before ADR-007 was accepted). If you encounter a checkout where
> these paths are still symlinks, re-run `just bootstrap` to materialise the
> real submodule worktrees.

## Prerequisites

- You have cloned the Odysseus repo with submodules (`just bootstrap`).
- You have standalone clones of AchaeanFleet, Myrmidons, and ProjectMnemosyne repositories (see Step 6).
- You have write access to AchaeanFleet, Myrmidons, and ProjectMnemosyne repos.
- Podman is installed and the Podman socket is running (ADR 001).
- Agamemnon is running and accessible at `$AGAMEMNON_URL`.

---

## Steps

### 1. Create the Dockerfile in AchaeanFleet

Navigate to the AchaeanFleet submodule and create a new vessel directory:

```bash
cd infrastructure/AchaeanFleet/vessels/
mkdir <agent-name>
```

Create a `Dockerfile` in that directory. Follow the conventions in existing vessels:
- Base image should be a minimal, OCI-compatible image.
- The entrypoint should be the agent binary or script.
- Include a `LABEL hi.agamemnon.agent-type=<agent-name>` for discoverability.
- Document required environment variables in a comment block at the top of the Dockerfile.

### 2. Build the vessel image

From the AchaeanFleet root:

```bash
cd infrastructure/AchaeanFleet
just build-vessel <agent-name>
```

This builds the image and tags it as `homeric-intelligence/<agent-name>:latest`. Verify the build succeeded:

```bash
podman images | grep <agent-name>
```

### 3. Verify with Agamemnon agent launch

Test that Agamemnon can launch a container from the new image:

```bash
curl -X POST $AGAMEMNON_URL/v1/agents \
  -H "Content-Type: application/json" \
  -d '{
    "image": "homeric-intelligence/<agent-name>:latest",
    "name": "test-<agent-name>",
    "env": {}
  }'
```

Check that the container starts and Agamemnon reports it as running:

```bash
curl $AGAMEMNON_URL/v1/agents | jq '.[] | select(.name == "test-<agent-name>")'
```

Clean up the test agent before proceeding:

```bash
curl -X DELETE $AGAMEMNON_URL/v1/agents/test-<agent-name>
```

### 4. Add a YAML template to Myrmidons

Navigate to Myrmidons and add a template for the new agent type:

```bash
cd provisioning/Myrmidons/_templates/
```

Create `<agent-name>.yaml` following the format of existing templates. At minimum, include:
- `name`: a template variable (e.g., `{{ name }}`)
- `image`: `homeric-intelligence/<agent-name>:latest`
- `env`: required environment variables as template variables
- `tags`: include `agent-type: <agent-name>` for filtering

### 5. Register in ProjectMnemosyne marketplace.json

Navigate to ProjectMnemosyne and add the new agent type to the marketplace catalog:

```bash
cd shared/ProjectMnemosyne
```

Edit `marketplace.json` to add an entry for the new agent type. Include:
- `name`: human-readable name
- `type`: `<agent-name>`
- `image`: `homeric-intelligence/<agent-name>:latest`
- `description`: what the agent does
- `template`: path to the Myrmidons template (e.g., `provisioning/Myrmidons/_templates/<agent-name>.yaml`)
- `version`: `1.0.0`

### 6. Commit and push changes

Per [ADR-007](../adr/007-symlinks-over-submodules.md) (**Accepted**), the
submodule paths are real git submodule worktrees. You can `cd` into each
submodule path inside the Odysseus checkout and commit there directly; the
final step is to bump the recorded submodule SHA in the Odysseus root:

#### 6a. Commit in AchaeanFleet submodule

```bash
cd infrastructure/AchaeanFleet
git add vessels/<agent-name>/
git commit -m "feat: add <agent-name> vessel"
git push origin main
```

#### 6b. Commit in Myrmidons standalone clone

Navigate to your Myrmidons repository clone:

```bash
cd /path/to/Myrmidons
git add _templates/<agent-name>.yaml
git commit -m "feat: add <agent-name> template"
git push origin main
```

#### 6c. Commit in ProjectMnemosyne standalone clone

Navigate to your ProjectMnemosyne repository clone:

```bash
cd /path/to/ProjectMnemosyne
git add marketplace.json
git commit -m "feat: register <agent-name> in marketplace"
git push origin main
```

#### 6d. Update submodule pins in Odysseus (optional)

If you have pinned specific commit SHAs in the Odysseus `.gitmodules` for these repos, return to Odysseus and update those pins:

```bash
cd /path/to/Odysseus
git add .gitmodules
git commit -m "chore: update submodule pins for <agent-name> agent type"
git push origin main
```

Otherwise, the symlinks in Odysseus will point to the latest main branch of each repo, and no pin update is needed.

---

## Verification Checklist

- [ ] `Dockerfile` created in `infrastructure/AchaeanFleet/vessels/<agent-name>/`
- [ ] `just build-vessel <agent-name>` succeeds
- [ ] Agamemnon `/v1/agents` can launch a container from the image
- [ ] Template added to `provisioning/Myrmidons/_templates/<agent-name>.yaml`
- [ ] Entry added to `shared/ProjectMnemosyne/marketplace.json`
- [ ] Submodule pins updated in Odysseus root
- [ ] ProjectProteus CI pipeline passes for all modified repos
