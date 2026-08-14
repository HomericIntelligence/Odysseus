# Runbook: Disable GitHub Code Quality on All HomericIntelligence Repos

> **Why:** GitHub Code Quality is a public preview that **becomes a paid product
> on 2026-07-20**. Continuing to leave it enabled will start incurring charges
> per-CodeQL-scan after GA. This runbook disables it across the entire
> HomericIntelligence organization.
>
> **When:** ideally before 2026-07-20. For pure-org public repos the feature
> remains free of charge even after GA, but disabling still stops the PR
> annotations the feature generates.
>
> **Audit:** `just code-quality-audit` (or `just code-quality-audit-all` for all
> 17 org repos). Re-run after each repo is flipped.

This runbook covers the **UI-driven** disable path. On the free GitHub plan
there is no REST endpoint for Code Quality enable/disable — every PATCH against
`/repos/{r}/code-quality` returned HTTP 404 (enterprise-tier endpoint) or HTTP
422 (invalid payload). It must be flipped manually per repo.

---

## TL;DR — execute these 17 manual clicks

For each of the 17 HomericIntelligence repos:

1. Open `https://github.com/HomericIntelligence/{repo}/settings/security_analysis`
2. Scroll to **Code quality**.
3. Click **Disable**.
4. Confirm: **Yes, disable**.

The full URL list is in §4 below.

---

## 1. What this runbook does and does NOT disable

| Feature | Free for public repos? | Touched here? | Why |
|---------|------------------------|---------------|-----|
| GitHub Code Quality | yes (preview) → **paid at GA on 2026-07-20** | **yes (this runbook)** | goal of the runbook |
| CodeQL code scanning (security) | yes | no | distinct feature; not what the user wants to disable |
| Dependabot security / version updates | yes | no | distinct feature; not what the user wants to disable |
| Secret scanning + push protection | yes | no | distinct feature; not what the user wants to disable |

If you want to also disable any of those, that's a separate decision — file an
issue and write a new runbook.

---

## 2. Where Code Quality is NOT controlled

The natural assumption that "branch rulesets" is where Code Quality lives is
worth checking explicitly:

- **`configs/github/org-ruleset.json`** & **`configs/github/org-ruleset-active.json`**
  — both the canonical org-level rulesets. Verified **not** to include the
  `Require code quality results` rule type. ✓ (correct)
- **`configs/github/repo-ruleset.json`** & **`configs/github/repo-ruleset-active.json`**
  & **`configs/github/repo-ruleset-evaluate.json`** — the per-repo canonical
  rulesets. Same: NOT included. ✓ (correct)
- **`configs/github/backups/branch-protection-pre-ruleset.json`** — a
  **historical** snapshot of the classic branch protection settings that
  predates the ruleset migration. Lines 474/523 mention a `"Code Quality
  Analysis"` status check. This file is archived; it is NOT enforced.
- **The free GitHub plan** has no `Require code quality results` rule in our
  active configuration. Adding it would ENFORCE Code Quality as a merge gate —
  which is the opposite direction from "disable".

**Conclusion:** Code Quality is currently NOT enforced by any ruleset, so there
is nothing to remove at the ruleset level. To actually have the feature **off
on disk**, you must disable per-repo via UI (this runbook).

---

## 3. Sequence of actions

### Step 1 — Snapshot the starting state

From this Odysseus meta-repo:

```bash
mkdir -p docs/diagnostics
just code-quality-audit > docs/diagnostics/code-quality-before.md
just code-quality-audit-all > docs/diagnostics/code-quality-before-all.md
```

These show the current Code Quality / Code Scanning / Dependabot / Secret
Scanning state on each HomericIntelligence repo.

### Step 2 — Disable per repo (UI)

For each of the 17 repos in §4:

1. Open the settings URL.
2. Scroll to **Code quality**.
3. Click **Disable**.
4. Confirm.

### Step 3 — Verify

```bash
just code-quality-audit        # 16 repos (.gitmodules + Odysseus)
just code-quality-audit-all    # all 17 in the org, incl. modular-community
```

Expected outcome per repo: **Code Quality** column shows `off` or `404`. Any
repo still showing `on`/`enabled` means you missed that one. Re-do §2 for it.

### Step 4 — Optional: write the audit snapshot into CI

```bash
just code-quality-update       # writes docs/ecosystem-code-quality-status.md
```

This file is suitable as a CI job artifact, a Slack status post, or a
`$GITHUB_STEP_SUMMARY` summary block.

---

## 4. The 17 repos — one URL each

| # | Repo | Settings → Code Quality URL |
|---|------|------|
| 1  | AchaeanFleet     | `https://github.com/HomericIntelligence/AchaeanFleet/settings/security_analysis` |
| 2  | Agamemnon        | `https://github.com/HomericIntelligence/Agamemnon/settings/security_analysis` |
| 3  | Argus            | `https://github.com/HomericIntelligence/Argus/settings/security_analysis` |
| 4  | Athena           | `https://github.com/HomericIntelligence/Athena/settings/security_analysis` |
| 5  | Charybdis        | `https://github.com/HomericIntelligence/Charybdis/settings/security_analysis` |
| 6  | Hephaestus       | `https://github.com/HomericIntelligence/Hephaestus/settings/security_analysis` |
| 7  | Hermes           | `https://github.com/HomericIntelligence/Hermes/settings/security_analysis` |
| 8  | Keystone         | `https://github.com/HomericIntelligence/Keystone/settings/security_analysis` |
| 9  | Mnemosyne        | `https://github.com/HomericIntelligence/Mnemosyne/settings/security_analysis` |
| 10 | modular-community | `https://github.com/HomericIntelligence/modular-community/settings/security_analysis` |
| 11 | Myrmidons        | `https://github.com/HomericIntelligence/Myrmidons/settings/security_analysis` |
| 12 | Nestor           | `https://github.com/HomericIntelligence/Nestor/settings/security_analysis` |
| 13 | Odysseus         | `https://github.com/HomericIntelligence/Odysseus/settings/security_analysis` |
| 14 | Odyssey          | `https://github.com/HomericIntelligence/Odyssey/settings/security_analysis` |
| 15 | Proteus          | `https://github.com/HomericIntelligence/Proteus/settings/security_analysis` |
| 16 | Scylla           | `https://github.com/HomericIntelligence/Scylla/settings/security_analysis` |
| 17 | Telemachy        | `https://github.com/HomericIntelligence/Telemachy/settings/security_analysis` |

> The 16 submodules referenced from this meta-repo's `.gitmodules` PLUS
> `Odysseus` itself cover the same set as rows 1–9, 11–17 above. `modular-community`
> (row 10) is not pinned by this meta-repo but is in the org and is covered by
> `--all` mode of the audit.

---

## 5. UI navigation screenshots (textual)

The exact UI text and field names, in case the visual layout changes:

1. Repo page → top-right **Settings** cog icon.
2. Left sidebar → **Code security and analysis** (under "Security" section).
3. Section labeled **Code quality**.
4. Button reads **Disable** when on; reads **Enable** when off.
5. Confirmation modal: **Yes, disable Code quality**.

---

## 6. CI integration candidate

The audit script can run as a scheduled CI job. Pseudocode:

```yaml
- name: Audit Code Quality state
  run: just code-quality-update
- name: Fail if Code Quality is on anywhere
  run: |
    if grep -q '| .* | on ' docs/ecosystem-code-quality-status.md; then
      echo "ERROR: Code Quality is enabled on at least one repo"
      grep -E '\| .* \| on \|' docs/ecosystem-code-quality-status.md
      exit 1
    fi
```

This is intentionally not wired into the Odysseus CI yet — it would belong in
`configs/github/` consumer-side infrastructure or a future HomericIntelligence
"org-wide policy enforcement" workflow. File an issue if you want this.

---

## 7. Programmatic disable (when the API lands)

If/when GitHub exposes `PATCH /repos/{r}/code-quality` on the free public org
tier, the deliverable for full automation is:

```bash
# tools/disable-code-quality.sh (future)
for repo in $(just code-quality-audit-all | awk '/^| .* | on /{print $2}' | tr -d '|'); do
  gh api -X PATCH "repos/HomericIntelligence/$repo/code-quality" \
    -H 'Accept: application/vnd.github+json' \
    -f "enabled=false"
done
```

Until that endpoint exists, this runbook is the source of truth.

---

## 8. Recovery / opt back in

To opt a repo INTO Code Quality again (e.g. for a one-off experiment):

1. Open the repo's **Settings → Code security and analysis → Code quality**.
2. Click **Enable**.
3. Optionally commit a `.github/codeql/code-quality-config.yml` to customize
   the queries that run.

The `Require code quality results` ruleset rule **must remain absent** from the
HomericIntelligence `homeric-main-baseline` rulesets. Adding it would ENFORCE
Code Quality as a merge gate and would silently re-introduce the cost we're
trying to avoid.

---

## Appendix — related canonical config files

- **`configs/github/canonical-checks.md`** — the 8 (or 11 per-repo) required
  status checks enforced by the `homeric-main-baseline` ruleset. The Code Quality
  toggle is orthogonal to this list.
- **`configs/github/org-ruleset.json`** + **`org-ruleset-active.json`** — org-level
  ruleset. NOT modified by this runbook. `Require code quality results` is
  intentionally not present. See `just ruleset-enforcement-check`.
- **`configs/github/repo-ruleset.json`** + **`active.json`** + **`evaluate.json`** —
  per-repo rulesets. Same: NOT modified by this runbook.
- **`configs/github/backups/branch-protection-pre-ruleset.json`** — historical
  snapshot. Mentioned for reference; do not edit.

See also:

- `tools/probe-code-quality.sh` — the audit script this runbook points at.
- `just code-quality-audit` / `just code-quality-audit-all` / `just code-quality-update`
  / `just code-quality-runbook` — the entry points.
