# Runbook: Lane Model Pinning (ADR-020 §4)

Pins the four automation-lane model IDs as configuration so loop launches and
Myrmidons manifests never rely on opencode's ambient default. The canonical
pin file is `configs/lane-models.yaml`; changing a lane model is a one-line
edit there. Operator lane runs **opencode**; Claude remains available for
other contributors.

## Lane pin (operator-confirmed in issue #465)

| Lane | Pinned ID | Roles |
|---|---|---|
| Planning | `opencode/x-preview-f-free-high` | chief-architect roles |
| Implementation | `opencode/x-preview-f-free-medium` | task-agent roles |
| Review | `opencode/x-preview-f-free-low` | plan-reviewer / pr-reviewer |
| Mechanical | `opencode/x-preview-f-free-low` | merger / seeder / learn / advise |

## Steps

1. Verify the current pin parses and print the table:

   ```bash
   just lane-models
   ```

2. Launch the loop with the pinned IDs (source-able exports for the launch
   shell; Hephaestus reads `HEPH_PLANNER_MODEL`, `HEPH_IMPLEMENTER_MODEL`,
   `HEPH_REVIEWER_MODEL`, `HEPH_LEARN_MODEL`, `HEPH_ADVISE_MODEL` when no
   explicit model is passed):

   ```bash
   eval "$(just loop-env)"
   # then start the loop with --agent opencode from the Hephaestus env
   ```

3. Change a lane model (one line, config only — never code):

   ```bash
   $EDITOR configs/lane-models.yaml   # edit the one lane line
   bash tests/test-lane-models.sh     # validates + proves propagation
   git add configs/lane-models.yaml && git commit -m "chore: retune <lane> lane model"
   ```

4. Myrmidons manifests (cross-repo follow-up, lands with M3 per
   `workflows/m3-containerized-pipeline.yaml`): set each manifest's `model:`
   field from this table —

   - chief-architect manifest → planning ID
   - task-agent manifest → implementation ID
   - future plan-reviewer / pr-reviewer manifests → review ID
   - merger / seeder / learn manifests → mechanical ID

   Per AGENTS.md, submodule working trees are not edited from Odysseus; the
   manifest PR is filed in the Myrmidons repository.

## Scope notes

- `e2e/claude-myrmidon.py` is untouched (deprecated at M4, ADR-020 §9).
- The workflow registry points at the canonical file via
  `workflows/m0-contracts.yaml` (`lane_models: configs/lane-models.yaml`).
