# HomericIntelligence Agent-Instruction Modernization Disposition Ledger

This is the governance ledger for modernizing live agent-facing surfaces in
Odysseus and its 15 canonical component repositories. It records disposition,
ownership, dependencies, protected boundaries, and the evidence still required.
It is not evidence that a downstream change, deployment, or validation has
occurred.

## Inventory binding

Wave 0 is based on Odysseus remote `main` commit
`ccc6c15ce1d791a88ee72eb67b6d3bfef419a4e5`. The following default-branch
heads were read from GitHub on 2026-09-14. They are discovery snapshots, not
approved implementation bases: every repository must be rebound to its current
remote head in a fresh isolated worktree immediately before its implementation
PR.

The 16-repository membership was cross-checked between `.gitmodules` and
`configs/github/fleet-ruleset-policy.json`. `.gitmodules` enumerates the 15
components; adding the Odysseus root produces the same 16-name set as the
policy file.

| Repository | Default branch | Discovery SHA |
|---|---|---|
| Odysseus | `main` | `ccc6c15ce1d791a88ee72eb67b6d3bfef419a4e5` |
| Athena | `main` | `438e89c89ac24fe62257bef9d042f69a2a47147a` |
| Agamemnon | `main` | `50711aca12c251a4020aa99465047f602183c42d` |
| Nestor | `main` | `14ec5c133c8eed0dcafa616eef389717a745da97` |
| AchaeanFleet | `main` | `ede530d7645d721bec0fd3d3b875bc6a959b624c` |
| Argus | `main` | `f1d5161d4e5809948b3bb22339c385e3f9df5738` |
| Hermes | `main` | `c89b52ae41f69ce485d616927fd3ad32f78b8332` |
| Telemachy | `main` | `b6af623a041e5cc6c5fe63efaf3e3bec75becfa9` |
| Myrmidons | `main` | `a0a8224647a98d6ec171aea32782cdde858d586c` |
| Keystone | `main` | `2deac49b17b2ef44371c56243c44eae27d5564ad` |
| Proteus | `main` | `3e952b6e48c1ccb34a010a60a9ccaac8ab4cc645` |
| Hephaestus | `main` | `f6d9077ff602c8c7f21d9f8c8566fea2800c43d9` |
| Mnemosyne | `main` | `03b050add8058048ac7d0b26d5956fed5ad8ec59` |
| Odyssey | `main` | `a8e1038001fa086a7df30874634b16a4dce7c977` |
| Scylla | `main` | `81d8292939dbafded7f1aca0530143a814e06334` |
| Charybdis | `main` | `2891cd4f9a9618ac639cfe7e64cf36293716816b` |

## Evidence limits

- The remote-head query proves only the named branch pointers at query time. It
  does not prove repository contents, consumer absence, deployed state, or test
  results.
- Component findings below come from the approved modernization inventory.
  Before an edit or deletion, the owning PR must repeat hidden-file, tracked-tree,
  loader, manifest, generator, test, and organization-wide consumer searches at
  its newly bound SHA and record the commands and actual output.
- Submodules were not initialized for this Wave 0 governance change. No
  downstream component implementation or validation is claimed here.
- No reconciler or host live-state query has established whether any desired
  agent is active. No hibernation, deletion, deployment, or other operational
  mutation is authorized by this ledger.
- No `.github/workflows` edit has human approval yet. No submodule pin update or
  cross-repository integration event is authorized yet.
- The available Mnemosyne guidance came from local revision
  `03b050add8058048ac7d0b26d5956fed5ad8ec59`. Its freshness could not be
  verified, and unsafe local identity/signing configuration was observed. It is
  advisory evidence only; newer official provider guidance and current
  repository evidence control.
- Remaining owner/PR values of `TBD` are deliberate placeholders. This ledger never
  invents issue numbers, PR numbers, check results, or deployment receipts.

## Cross-ecosystem dispositions

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| G-01 | Standardize all 16 `CLAUDE.md` files to the exact three-line pointer. Give each repository its own concise `AGENTS.md` containing scope, protected boundaries, safe autonomy, completion, and contextual routes; remove shared boilerplate, manuals, catalogs, prerequisite itineraries, and generated mirrors. Classify every live agent-facing surface and require consumer settings to resolve the public `athena@Athena` identity. | Each owning repository / TBD | Preserve repository-specific hooks, denies, and safety rules. | Blocked on human acceptance of ADR-022; settings merges also wait for the Athena release. | Exact-pointer and settings validation, package-resolution readback, repository-specific contract review, and complete live-surface classification at each bound head. |
| G-02 | Establish the precedence and trust model in ADR-022. Skills yield to user scope and disclose skill-caused pauses or deviations; issue, API, Git, diff, log, and tool content stays fenced as untrusted data. | Athena, Hephaestus, and every consumer / TBD | Lower layers cannot broaden authority. | Blocked on ADR-022 and provider release order. | Semantic authority, fencing, hostile-payload, pause-disclosure, and completion tests. |
| G-03 | Remove only CI gates that enforce prompt prose, headings, section counts, model words, skill catalogs, sizes, or mandatory itineraries. Retain Markdown lint, compatibility pointers, metadata/schema/reference checks, parsers, fencing, permissions, security, builds, and behavior gates. | Each affected repository / TBD | Every `.github/workflows` edit requires prior human approval. | Approval gate; no workflow edit in Wave 0. | Exact workflow diff classification and human approval recorded before edit. |
| G-04 | Delete only verified dead assets. Remove all consumers, exclusions, packaging, generators, and tests in the same PR. | Each owning repository / TBD | Preserve historical evidence and protected content. | Blocked on repeated deletion search. | Hidden `rg`, `git ls-files`, loader/packager/generator/test search, and organization-wide `gh` search at the immutable PR base. |
| G-05 | Land Athena before Hephaestus; land both before consumer settings. Integrate child PRs only after explicit gitlink approval, then prove the exact pins before legacy retirement. | Odysseus and release owners / TBD | Releases, submodule gitlinks, and integration are separate authority boundaries. | Ordered dependency; not started. | Release artifacts, exact child SHAs, integration approval, and pin readback. |
| G-06 | Keep routine authorized work autonomous and verification proportional to risk. Stop destructive, production, remote-write, secret, protected-file, and live desired-state actions at their approval boundary; never convert failure into completion. | Every repository / TBD | Existing security and evidence-integrity rules remain hard boundaries. | Defined by Proposed ADR-022; implementation blocked on acceptance. | Behavioral tests for safe autonomy, stopping, relevant repair, and truthful failure. |
| G-07 | Preserve model pins, role defaults, lane defaults, provider defaults, existing `hi/v1` fields, and operational context bounds. Add no instruction-size measurements or gates and no prompt-text snapshots. | Every repository / TBD | Compatibility invariant. | Active constraint. | Configuration/schema diffs and semantic tests prove no default or wire drift. |

## Odysseus

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| O-01 | Two Proposed ADRs used number 009. Renumber the Nomad-deferral proposal to ADR-021 and update its live references; retain NATS authentication as ADR-009. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509) | Do not edit Accepted ADR bodies. | Implemented by PR #509; both affected ADRs retain their recorded status. | Tracked/hidden reference search, ADR status check, Markdown validation, and PR diff. |
| O-02 | Add Proposed ADR-022, “Layered, Provider-Neutral Agent Instructions,” referencing ADR-020 and existing mesh/task schemas rather than duplicating them. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509) | Proposal only; dependent PRs wait for human acceptance. | Implemented in PR #509; acceptance pending. | Human decision plus exact accepted revision before downstream work starts. |
| O-03 | Repair incomplete or inaccurate ADR indexes and current-versus-proposed claims. Keep evidence integrity as direct repository policy without representing Proposed ADR-014 as Accepted. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509) | Accepted ADRs stay byte-unchanged. | Implemented by PR #509; direct repository policy and ADR status remain distinct. | Header-to-index comparison, protected-file diff, link and Markdown checks. |
| O-04 | Slim the root contract and correct repository counts, knowledge fallback, historical ai-maestro wording, host-mount claims, runbooks, onboarding, and `just`/`pixi` routing. | Odysseus / TBD | Preserve operational safety and evidence policy. | Wave 1; blocked on ADR-022 acceptance. | Fresh full inventory and focused docs checks. |
| O-05 | Make Telemachy workflow manifests canonical for future M0–M6 task descriptions; make milestone issue generation render them rather than duplicate prose. Do not rewrite closed issue bodies. | Odysseus and Telemachy / TBD | Closed issues are immutable historical records; wire fields stay unchanged. | Wave 1; blocked on ADR-022 and cross-repo coordination. | Generator parity tests and search proving duplicate live prose was removed. |
| O-06 | Update issue and PR templates to express outcome, scope, allowed effects, relevant checks, completion, and stopping conditions; remove blanket full-suite and submodule-pin suggestions. | Odysseus / TBD | Template changes grant no new remote-write or pin authority. | Wave 1; blocked on ADR-022. | Rendered-template review and focused checks. |
| O-07 | Install only Athena's plugin skills, use `.agent_brain/knowledge`, and remove duplicate Hephaestus skill installation. | Odysseus / TBD | Preserve plugin identity `athena@Athena`; do not mutate user caches as proof. | Wave 1; blocked on Athena migration/release. | Installer dry run in an isolated destination plus file inventory. |
| O-08 | Make hierarchy sync report unavailable/failure when submodules are absent and expose the documented `just` entry point. | Odysseus / TBD | No false-green result. | Wave 1 runtime change; blocked on ADR-022. | RED test for absent submodules, GREEN behavior, and `just` invocation. |
| O-09 | While legacy harnesses remain, fence issue text, reject malformed routing rather than fan out to all repositories, require exact verdict schemas, propagate invocation failures, enforce protected scopes, and emit completion only after verified terminal evidence. | Odysseus / TBD | Preserve tool scopes, container isolation, timeouts, and protected paths. | Wave 1 safety work; blocked on ADR-022. | RED-GREEN tests for every failure/trust branch and bounded E2E evidence. |
| O-10 | Open issue #478 conflicts with this modernization by requiring the obsolete 91-principle mirror and `@AGENTS.md` pointer. Reconcile or retire it only after ADR-022 acceptance. | Odysseus / TBD | Do not edit the issue or associated workflows in Wave 0; workflow consequences require human approval. | Live conflict recorded; no mutation authorized. | Fresh issue readback, dependency decision, and approval record. |
| O-11 | Remove editorial workflow gates only under the protected-workflow process. Move any live inline prompt into versioned resources. | Odysseus / TBD | `.github/workflows` requires human review. | Wave 6 approval gate. | Classified diff and retained-gate checklist. |
| O-12 | Update submodule pins only once all child PRs and provider releases land. | Odysseus / TBD | `.gitmodules` and gitlinks require explicit integration approval. | Wave 6; not authorized. | Exact child release/merge SHAs and integration readback. |
| O-13 | On exact integrated pins, prove routing, three-heavy-worker concurrency, timeouts, isolation, tool scopes, restart/retry, issue binding, PR lifecycle, and truthful receipts; run one real ADR-020 M4 mesh-only dogfood issue. Retire both legacy harnesses only in a later separate reviewed PR after proof passes, preserving Hephaestus single-device fallback. | Odysseus and mesh owners / TBD | Real operational run and legacy deletion require human-reviewed boundaries; raw evidence is immutable. | Wave 7; blocked on integration. | Actual terminal receipts or truthful failure; unit/simulation evidence alone is insufficient. |
| O-14 | Correct proposal-era authority wording across schema annotations, milestone task sources and generation, tooling comments, ADR-014 context, and runbooks without changing the `hi/v1` contract or existing milestone identities and dependency edges; add M4.8 as the explicit exact-pin dogfood closure task. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509) | `hi/v1` fields, enums, subjects, existing milestone identities and dependency edges, and mesh runtime defaults remain unchanged. M4.8 is the sole milestone addition: an operator-held gate with six repository-qualified verification prerequisites and no parser dependency edges. | Attribution corrections and the M4 closure task are implemented by PR #509; compatibility evidence belongs to that PR. | Schema diff proves annotations only, plus schema fixtures, milestone parser/generator tests, and documentation checks. |
| O-15 | Open PR #498 and its stacked PRs #503, #505, and #507 carry a different Proposed ADR-021 for Fleet execution. Keep ADR-021 assigned to the Nomad-deferral proposal in this approved modernization plan; reserve the next unused number, ADR-023, for the Fleet proposal. The Fleet stack must rebase after PR #509, rename the ADR and all live references, and pass the unique-number check before merge. | Odysseus / PRs [#498](https://github.com/HomericIntelligence/Odysseus/pull/498), [#503](https://github.com/HomericIntelligence/Odysseus/pull/503), [#505](https://github.com/HomericIntelligence/Odysseus/pull/505), and [#507](https://github.com/HomericIntelligence/Odysseus/pull/507) | PR #509 does not mutate or merge the Fleet stack; accepted ADR bodies remain unchanged. | Collision recorded from live PR inspection; Fleet renumber/rebase remains required before that stack can merge. | All-state PR search, exact-head/blob readback, post-rebase unique-number check, and updated ADR index/reference search. |
| O-16 | The current milestone checklist and pinned Agamemnon planning parser identify issues only as repository-blind `#N` values. Keep existing machine checklist grammar unchanged; render M4.8 outside that parser surface as an operator-held gate with repository-qualified evidence links. Add repository-aware identity and dependency parsing only in a coordinated producer/Agamemnon change after ADR-022 acceptance. | Odysseus and Agamemnon / TBD | Preserve current `hi/v1` fields and exact-pin parser behavior; do not claim automated cross-repository dependency enforcement. | Wave 3; blocked on ADR-022 acceptance and a consumer compatibility plan. | Exact-pin parser fixtures for duplicate cross-repository issue numbers, producer/consumer compatibility tests, and one real M4 proof. |
| O-17 | PR #508 contains a malformed immutable Athena round-2 carrier and cannot support verified review delivery. Preserve its review evidence, supersede it with PR #509 at the same corrected source lineage, and start a new target-bound exchange. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509), superseding [PR #508](https://github.com/HomericIntelligence/Odysseus/pull/508) | Do not edit, delete, dismiss, or reuse the malformed review record. Do not merge PR #508. | Replacement PR established; PR #508 closed unmerged after exact replacement readback. | Exact target, base, head, body, branch, and review-history readback for both pull requests. |
| O-18 | Milestone registration treated deterministic public body markers as ownership, allowed a marked issue to hide a same-title duplicate, and skipped child verification after finding an epic. Require exact canonical bodies, unambiguous identity, a dedicated non-state operator-gate label, complete read-only preflight before writes, strict intake state for partial creation, and lifecycle-aware validation for registered epics against the pinned Hephaestus issue-label contract. | Odysseus / [PR #509](https://github.com/HomericIntelligence/Odysseus/pull/509) | Never adopt or relabel an untrusted issue. Existing issue bodies and labels are not mutated; issue/PR state ownership and mesh defaults remain unchanged. | Implemented as a PR-review repair in PR #509. | RED-GREEN spoof, duplicate, body-drift, zero-write, existing-epic, partial-retry, and exact-pin lifecycle tests; raw GitHub body readback; propagated-command-failure checks. |

## Athena

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| AT-01 | Remove the generated 91-principle root mirror and broad default prompt; make the repository contract concise. | Athena / TBD | Preserve unique security and workflow constraints. | Wave 2; blocked on ADR-022. | Fresh generated-source and consumer search. |
| AT-02 | Refactor all 17 existing skills without renaming IDs. Make each root `SKILL.md` a discriminating router and move detail to contextual references/scripts; retain strict review, worktree, exchange, and evidence state machines. | Athena / TBD | Public identity remains `athena@Athena`; do not add `agents/openai.yaml`. | Wave 2; blocked on ADR-022. | Package inventory proves exactly 17 stable IDs; branch-level workflow tests. |
| AT-03 | Replace mandatory-section and exact-wording checks with structural metadata, dependency, reference, package, and executable-workflow validation. | Athena / TBD | Retain security, dependency, executable, and package failures. | Wave 2; protected workflow edits separately gated. | Semantic fixture tests including malformed metadata and broken references. |
| AT-04 | Release Athena before Hephaestus or any consumer settings merge. | Athena / TBD | Release authority remains separate. | Ordered release gate. | Published release identity and consumer-resolvable readback. |

## Mnemosyne

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| MN-01 | Slim only the root contract and future authoring guidance. | Mnemosyne / TBD | Existing knowledge content is out of scope. | Wave 2; blocked on ADR-022. | Path inventory proves edits are confined to contract/authoring infrastructure. |
| MN-02 | Grandfather all 783 live knowledge entries and 181 notes byte-for-byte. Do not rewrite them for new structure or wording. | Mnemosyne / TBD | Knowledge entries and notes are immutable for this migration. | Active invariant. | Pre/post path manifest and content hashes for the entire frozen set. |
| MN-03 | For future entries, remove mandatory five-section, size, model-pinned delegation, and duplicated-principle requirements while retaining global metadata, provenance, duplicate detection, and link integrity. | Mnemosyne / TBD | Do not weaken provenance or integrity validation. | Wave 2; protected workflow changes gated. | Legacy grandfather fixtures plus new-authoring semantic tests. |

## Hephaestus

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| HP-01 | Slim the root contract; remove stale skill/model catalogs, recursive writing-standard injection, duplicated terse directives, and fixed validation delegation. | Hephaestus / TBD | Preserve repository-specific execution and safety rules. | Wave 2; blocked on accepted ADR-022 and Athena release. | Loader/consumer inventory and focused prompt tests. |
| HP-02 | Rewrite every live prompt family around trusted operation, authority, completion, output, and provider guidance followed by ordered fenced payloads. | Hephaestus / TBD | Preserve template names, parsers, result schemas, tool scopes, state machines, and resource bounds. | Wave 2. | Per-family semantic tests and hostile-payload fence tests. |
| HP-03 | Add an invocation-local Astra supplement only for Codex whose parsed base model is exactly `gpt-6-astra`, optionally with the existing effort suffix. Apply exactly once on new and resumed turns, outside untrusted fences; exclude empty/default, literal `astra`, and every other model. | Hephaestus / TBD | No model/provider default or process-global switch. | Wave 2 runtime change. | RED-GREEN matrix covering provider, model, suffix, resumption, multiplicity, and fence placement. |
| HP-04 | Replace editorial sentinel/snapshot tests with semantic tests of authority, output, fencing, failure, completion, and preserved interfaces. | Hephaestus / TBD | Parser/schema/tool-scope/security checks remain. | Wave 2; workflow edits separately gated. | Mutation-resistant behavior tests. |
| HP-05 | Release after Athena, before consumer settings. | Hephaestus / TBD | Release authority remains separate. | Ordered release gate. | Published release and downstream resolution evidence. |

## Agamemnon

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| AG-01 | Modernize contract/settings, remove two tracked issue-specific prompt artifacts, and correct language/tooling, peer-communication, store, and HTTP semantics docs. | Agamemnon / TBD | Delete only after repeated consumer search; preserve API behavior. | Wave 3; blocked on provider releases. | Hidden/tracked/loader/test/org search and docs validation. |
| AG-02 | Round-trip optional `model` through store, OpenAPI, Python client, reconciler, rollback, and export. | Agamemnon / TBD | No model default change. | Wave 3 runtime/API change. | RED-GREEN persistence, rollback, export, and OpenAPI compatibility tests. |
| AG-03 | Canonicalize `programArgs` as `string[]`; accept a legacy scalar in `myrmidons/v1`, normalize it, and always emit arrays. | Agamemnon / TBD | Preserve `myrmidons/v1` compatibility. | Wave 3 runtime/schema change. | Scalar-input and array-input round-trip tests with array-only output. |
| AG-04 | Correct client and agent docs to state that both PUT and PATCH task updates merge, matching current implementation. | Agamemnon / TBD | Do not change the implemented merge semantics. | Wave 3. | Existing server behavior tests plus client documentation review. |
| AG-05 | Remove the broken local scaffolder and make Myrmidons the sole template owner. Transport task text unchanged and untrusted. | Agamemnon and Myrmidons / TBD | Preserve task description fields and wire shape; deletion search required. | Wave 3 cross-repo dependency. | Consumer search, task byte-preservation test, and fenced prompt-assembly test. |

## Telemachy

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| TE-01 | Correct NATS/persistence state, hook-bypass guidance, workflow descriptions, and obsolete follow-up/scaffolding files. | Telemachy / TBD | Delete only after consumer search; no hook bypass. | Wave 3; blocked on provider releases. | Current code/config readback and deletion inventory. |
| TE-02 | Use the canonical Agamemnon endpoint for both local and Docker agents. | Telemachy and Agamemnon / TBD | Preserve authentication and deployment defaults. | Wave 3 compatibility change. | RED-GREEN local/Docker endpoint parity tests. |
| TE-03 | Forward explicit `program` and `model` fields consistently without adding defaults. | Telemachy and Agamemnon / TBD | Empty/omitted values must retain existing meaning. | Depends on Agamemnon round-trip support. | Explicit/omitted field matrix across local and Docker agents. |
| TE-04 | Own canonical future one-off and M0–M6 task descriptions in workflow manifests; Odysseus generation consumes that source. | Telemachy and Odysseus / TBD | Existing task fields stay unchanged and descriptions remain untrusted. | Wave 1/3 cross-repo dependency. | Render parity and hostile-description fencing tests. |

## Myrmidons

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| MY-01 | Modernize contract/settings and canonicalize argument schemas with Agamemnon's scalar-input/array-output compatibility. | Myrmidons / TBD | Preserve desired-state defaults and schema version. | Wave 3; depends on Agamemnon. | Manifest schema and reconciliation compatibility tests. |
| MY-02 | Forty-three issue-8/22/69 agents and three fleets appear to request active state. Query the live reconciler and obtain operator approval first. If no task is active, land/apply a hibernation PR and verify shutdown, then delete manifests/fleets in a second PR. | Myrmidons and operator / two PRs TBD | Live desired state and deletion require explicit operator approval; never infer inactivity from Git. | Approval gate; no live query or mutation yet. | Reconciler readback, task-activity proof, operator approval, applied hibernation receipt, shutdown verification, then second-PR deletion search. |
| MY-03 | Move future one-off work into Telemachy tasks. | Myrmidons and Telemachy / TBD | No retroactive closed-issue rewrite. | Wave 3 after canonical workflow source. | New task path integration test and absence of new one-off manifests. |

## AchaeanFleet

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| AF-01 | Route topology and vessel facts to runtime sources; correct Eris/Pallas, networks, workspace commands, and counts in the contract/settings. | AchaeanFleet / TBD | Current Compose assignments remain unchanged. | Wave 3; blocked on ADR-022. | Runtime/config-derived documentation audit. |
| AF-02 | Remove unconsumed `AGENT_PROGRAM` and `AGENT_HEADLESS_FLAG` only after migrating any discovered consumer to explicit Agamemnon/Myrmidons fields. | AchaeanFleet, Agamemnon, Myrmidons / TBD | No model assignment or provider default change; deletion search required. | Consumer-discovery gate. | Hidden/tracked/Compose/loader/org search and integration tests. |

## Nestor

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| NE-01 | Route API, NATS, security, and release material to focused docs; correct uv/Conan and design-principle claims; remove orphaned skill references, hook-bypass and force-push advice, and directions to place public API docs in `AGENTS.md`. | Nestor / TBD | Retain service security and release controls; never permit hook bypass or force-push. | Wave 4; blocked on ADR-022/provider releases. | Current toolchain/API inventory, reference search, and docs checks. |

## Argus

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| AR-01 | Correct scope, application-code, concurrency, and protected-path claims; remove stale model/skill catalogs and the dangling cardinality-budget reference. | Argus / TBD | Preserve observability security and production boundaries. | Wave 4. | Current tree/config audit and link validation. |
| AR-02 | Migrate any discovered Atlas-review consumer to the standard Hephaestus path, then delete orphaned dispatch/aggregate scripts, charter, and links. | Argus and Hephaestus / TBD | Deletion follows consumer proof; remote review effects stay authorized. | Consumer-discovery gate. | Hidden/tracked/loader/test/org search and replacement-path behavior test. |

## Hermes

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| HE-01 | Retain async, subject, wire, configuration, lock, and HMAC invariants; remove contradictory synchronous-Agamemnon/stateless claims and speculative implementation recipes. Make README/OpenAPI the interface authorities. | Hermes / TBD | Preserve wire/security/locking behavior. | Wave 4. | Runtime/OpenAPI comparison and focused docs checks. |
| HE-02 | Repair Markdown checks that currently swallow failures. | Hermes / TBD | Keep Markdown lint; workflow edit needs human approval if applicable. | Wave 4/6. | RED fixture demonstrating false green, then propagated nonzero result. |

## Charybdis

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| CH-01 | Retain test-subject isolation, Agamemnon-only fault injection, guaranteed cleanup, explicit chaos authorization, and separate ASAN/TSAN runs. Slim contract/settings and correct completed ROADMAP items. | Charybdis / TBD | Chaos, cleanup, and sanitizer boundaries remain hard requirements. | Wave 4. | Subject isolation and cleanup tests plus roadmap/code correlation. |

## Keystone

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| KE-01 | Move any unique current C++ concurrency/security rule into focused docs, then remove the obsolete 34-agent hierarchy and agent-only scaffolding. | Keystone / TBD | Preserve unique concurrency/security invariants; deletion search required. | Wave 4. | Rule-deduplication map, consumer search, and C++ behavior checks. |
| KE-02 | Remove unused notes setup, replace stale `.clinerules` with a minimal `AGENTS.md` compatibility pointer, and retarget documentation checks. | Keystone / TBD | Retain valid compatibility and security checks. | Wave 4; workflow edits separately gated. | Loader/reference search and docs-check fixtures. |

## Proteus

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| PR-01 | Remove four transient follow-up artifacts and correct closed-issue, pytest, gitleaks, dispatch, and CHANGELOG claims. | Proteus / TBD | Closed issues and evidence remain untouched; deletion search required. | Wave 4. | Current pipeline/tooling inventory and consumer search. |
| PR-02 | Replace every-edit `just validate` guidance with path-scoped affected checks while preserving hard security denies. | Proteus / TBD | Security scans and deny rules remain mandatory where affected. | Wave 4/6. | Path matrix proves affected checks run and security cannot be skipped. |

## Odyssey

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| OD-01 | Retain and rewrite only `chief-architect`, `implementation-engineer`, `ci-failure-analyzer`, `code-review-orchestrator`, `general-review-specialist`, `mojo-language-review-specialist`, `numerical-stability-specialist`, `security-review-specialist`, and `test-review-specialist`; migrate consumers and remove overlapping roles. | Odyssey / TBD | Delete only after exact consumer mapping; preserve unique current rules. | Wave 5. | Registered-agent inventory and hidden/loader/test/org searches. |
| OD-02 | Refactor `chief-architect` atomically with its planning-script consumer. | Odyssey / TBD | No half-migrated producer/consumer interface. | Wave 5. | End-to-end planning fixture at one bound commit. |
| OD-03 | Modernize live analysis, planning, implementation prompts, commands, shared resources, hooks, and retained skills; remove stale Mojo versions, MCP recommendations, fixed-model guidance, and unconditional auto-merge instructions. | Odyssey / TBD | Preserve project-specific numerical, security, and test boundaries; no model default change. | Wave 5. | Current Mojo/tooling audit and semantic prompt tests. |
| OD-04 | Remove host-side permission bypass and fail closed under an explicit read-only tool policy. | Odyssey / TBD | Permission boundaries may only tighten. | Wave 5 security change. | RED-GREEN permission tests and denied-write evidence. |
| OD-05 | Remove nonexistent marketplace entries and obsolete skill-migration wiring. | Odyssey / TBD | Deletion search required. | Wave 5. | Marketplace/package/loader and organization-wide searches. |

## Scylla

| ID | Finding and disposition | Owner / PR | Protected boundary | Dependency / status | Required evidence |
|---|---|---|---|---|---|
| SC-01 | Slim eight operational agents and judge/tier prompts while preserving scoring semantics, JSON-only output, pre/post-pipeline meaning, no-code-execution, remote-write, and cleanup boundaries. | Scylla / TBD | Scoring and safety semantics are compatibility contracts. | Wave 5. | Golden semantic fixtures without prompt-text snapshots. |
| SC-02 | Repair the Codex adapter to use `codex exec` and explicit provider selection without adding a model default. | Scylla / TBD | No implicit model/provider selection. | Wave 5 runtime change. | RED-GREEN command construction and explicit/omitted provider tests. |
| SC-03 | Restore deleted Claude skill benchmark inputs exactly from the parent of deletion commit `acf03e5e` into a versioned legacy cohort, with provenance and hashes; update composer and counts to that immutable source. Do not create an Astra cohort. | Scylla / TBD | Historical Git objects and frozen cohort bytes are immutable. | Wave 5 history-bound change. | Git-object byte comparison and complete cohort hash manifest. |
| SC-04 | Delete 40 unregistered legacy plugin skills only after moving any unique current Scylla rule into focused documentation. Retain and routerize only genuinely live repository skills. | Scylla / TBD | Deletion search and rule-preservation proof required. | Wave 5. | Registry/loader/packager/test/org search and unique-rule map. |
| SC-05 | Never alter existing blocks, agents, subtests, tiers, or `docs/arxiv/dryrun/raw/**`. | Scylla / TBD | Frozen benchmarks and raw evidence are immutable. | Active invariant. | Pre/post tracked path and content hashes. |

## Completion dependencies

1. Merge this Wave 0 governance correction and obtain an explicit human
   acceptance decision for ADR-022.
2. Rebind and implement Athena, then release it.
3. Rebind and implement Hephaestus, then release it.
4. Rebind each consumer repository and implement non-protected changes with
   repository-specific behavior tests.
5. Obtain per-repository human approval before every protected workflow edit
   and operator approval before any desired-state mutation.
6. Land all child PRs, obtain explicit integration approval, and update gitlinks
   in one Odysseus integration PR.
7. Prove the exact integrated mesh and run the real M4 dogfood issue.
8. Only after successful proof, use a separate human-reviewed PR to retire the
   legacy Odysseus harnesses.
