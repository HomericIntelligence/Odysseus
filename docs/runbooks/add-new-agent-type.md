# Runbook: Add a New Agent Type to the HomericIntelligence Ecosystem

## Prerequisites

- You have cloned the Odysseus repo with submodules (`just bootstrap`).
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

Commit changes in each modified repo separately, then update the submodule pins in Odysseus:

```bash
# Commit in AchaeanFleet
cd infrastructure/AchaeanFleet && git add vessels/<agent-name>/ && git commit -m "feat: add <agent-name> vessel"

# Commit in Myrmidons
cd provisioning/Myrmidons && git add _templates/<agent-name>.yaml && git commit -m "feat: add <agent-name> template"

# Commit in ProjectMnemosyne
cd shared/ProjectMnemosyne && git add marketplace.json && git commit -m "feat: register <agent-name> in marketplace"

# Update submodule pins in Odysseus root
cd /path/to/Odysseus
git add infrastructure/AchaeanFleet provisioning/Myrmidons shared/ProjectMnemosyne
git commit -m "chore: update submodule pins for <agent-name> agent type"
```

---

## Verification Checklist

- [ ] `Dockerfile` created in `infrastructure/AchaeanFleet/vessels/<agent-name>/`
- [ ] `just build-vessel <agent-name>` succeeds
- [ ] Agamemnon `/v1/agents` can launch a container from the image
- [ ] Template added to `provisioning/Myrmidons/_templates/<agent-name>.yaml`
- [ ] Entry added to `shared/ProjectMnemosyne/marketplace.json`
- [ ] Submodule pins updated in Odysseus root
- [ ] ProjectProteus CI pipeline passes for all modified repos
