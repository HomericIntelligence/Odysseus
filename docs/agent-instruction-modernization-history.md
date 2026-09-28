# Historical PR #511 modernization ledger

This preserves the earlier ledger from commit
`084a94d4a0ce78079e09fd0eb07efe0ed003f06b` as historical evidence only.
Its approval, platform, ADR numbering, implementation, and check-status claims
apply to their recorded snapshots, not the current worktree. The current
[governance ledger](agent-instruction-modernization-ledger.md) controls the
inventory and disposition identifiers. Earlier `G-` identifiers below belong
to this historical record and do not identify current governance rows.
Current PR #511 review and CI remain incomplete; no historical GO transfers.

---

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
- This worktree runs on macOS while the checked-in Pixi workspace declares only
  `linux-64`. Canonical Pixi execution cannot run on this host; portable focused
  checks use isolated `uv` dependencies, and exact-head CI is authoritative for
  the Linux Pixi lane.
- Tailscale and live container execution are unavailable in this environment.
  Exact-head CI is authoritative for those paths; no local result in this
  ledger is represented as Tailscale, Podman, or live-service proof.
- The current Wave 1 overlay does not change Accepted ADR bodies,
  `.github/workflows`, `.gitmodules`, or component gitlinks. Those invariants
  must be rebound again at the final review head.
- The available Mnemosyne guidance came from local revision
  `611a59048c24ac3fcd9c9472c8452bc059f187b5`. Its freshness could not be
  verified, and unsafe local identity/signing configuration was observed. It is
  advisory evidence only; newer official provider guidance and current
  repository evidence control.
- The changed ADRs 010, 013, 014, 018, 019, 020, 021, 022, and 024 all remain
  `Proposed`. Nothing in this ledger treats those proposals as deployed or
  binding architecture. Accepted ADR bodies remain byte-unchanged.
- Remaining owner/PR values of `TBD` are deliberate placeholders. This ledger never
  invents issue numbers, PR numbers, check results, or deployment receipts.
- References to Odysseus PR #509 identify the superseded delivery attempt whose
  immutable review history is preserved. [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511)
  owns the current delivery. Its exact head, CI, and review state remain pending
  until the corresponding immutable receipts exist.

## Wave 1 bounded review snapshots

- A selected-document audit returned `GO` for an earlier worktree snapshot based
  on `f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba`, compared with remote `main`
  `ccc6c15ce1d791a88ee72eb67b6d3bfef419a4e5`. Its scope digest is
  `8b6f16b5155ceb2dd816d487844b2195cb1b5e07af3cc7799b457bdb29c6e92e`.
  The bounded scope was `README.md`, `docs/README.md`,
  `docs/architecture.md`, `docs/deployment.md`, `docs/onboarding.md`,
  `docs/repo-conventions.md`, and `docs/runbooks/add-new-agent-type.md`; pinned
  component Git objects and protected files were read-only evidence. The audit
  verified the 15-component/16-repository inventory, exact pinned component
  descriptions, current-versus-Proposed boundaries, `athena@Athena` ownership,
  the pinned 14-router current state versus the planned 17-skill state, and the
  documented recipes, mounts, image tag, and squash auto-merge method. It also
  verified that Accepted ADRs, workflows, `.gitmodules`, component gitlinks,
  NATS/Nomad configuration, and the `hi/v1` schema were byte-equal to remote
  `main`; the lane payload digest remained
  `ecd7b199ae2ad9471dd5469097fb1bcb3753f21c0fd04bc84a20be515c642cb3`.
  The retained audit records only the prefix `8cc00828...` for the digest of
  the seven currently listed paths;
  the retained review record does not identify the broader path manifest for a
  later reported `b8071769...` result. Neither older digest is promoted to a
  current-scope `GO`; the final exact-head PR review must bind the current
  documentation bytes. In the earlier snapshot, scoped `git diff --check`,
  `just --summary`,
  `bash scripts/check-doc-field-drift.sh`, and a stale-claim search passed. No
  network, Tailscale, or runtime-deployment action was used. That audit shell
  lacked Markdownlint; a separate portable `markdownlint-cli` run later passed
  the selected documents, while exact-head CI remains authoritative.
- An independent legacy-harness review returned `NO-GO` for an immutable,
  now-superseded snapshot based on
  `f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba`. Its scope digest is
  `fc2666edfadb53a673c525e01ee78237a2392fc4015fcf6de2838d91c67e8619`;
  the reviewed SHA-256 values are
  `ce2790053cebdeefa50f5297305fd646ac4992a9d9776e8f3c08541849949f4b`
  for `e2e/claude-myrmidon.py`,
  `aa6a3c6e910ce049ebe064753057d9c7528bb7070c22c5e17b61b62ceb074622`
  for `e2e/claude-myrmidon-multi.py`, and
  `e3ca7911701986027b5e711bca2813b0d93cae9d0a926402b9d5c3592c7f1049`
  for its test snapshot. The review found forged or partial Athena-carrier
  validation including raw-HTML gaps, non-head-bound CI and merge time-of-check
  gaps, an unbound foreign `pushurl`, a symlink-following test writer,
  incomplete root integration and approval binding, source-head versus merge-OID
  confusion, non-durable and non-idempotent shipping/fan-in, no operational
  host-wide three-heavy limit or heartbeat, unbounded review capture, and
  false-success progress logging. That exact snapshot is superseded by later
  repairs and the bounded final `GO` recorded below.
- An independent durable-runtime subreview returned `NO-GO` for scope digest
  `d9dec14a178fac4653d966f958b6cba12e34c4a03e6ef3cb61707c1f33d6bf67`.
  It bound `e2e/legacy_runtime.py` at SHA-256
  `8e6bbcabebe59b934a4fb67ab0007cab2dd0168f434357d29eb7d689ad29582e`
  and `e2e/tests/unit/test_legacy_runtime.py` at SHA-256
  `392426c44e688e3798732122a8634c667b0a550b15f7c149eb1c6ef40dda60af`.
  It found premature and mutable completion, unchecked candidate digests,
  untrusted outbox namespaces, unleased concurrent publication,
  repository-local rather than host-wide heavy limits, swallowed handler
  failures, pre-transaction lease clocks, Git-environment redirection, and a
  SQLite path race. That exact snapshot is superseded by later repairs. The
  current staged runtime and test have SHA-256
  `6ae05d5792b328067df08b22968015b820b8451f70d32ab99158c6a5481d1db1`
  and `010d9cf2837289156a5f2c94ebcbd48dba2e71ee6f241c52509b5ca54c732658`.
  They do not have a retained exact-scope `GO`; terminal and durability claims
  for this overlay remain pending an exact review.
- An independent milestone/hierarchy trust review returned `NO-GO` for scope
  digest
  `9b801fc90d9c7ea5e48f84fd749df073d259dee664087606d058934aadaa27b0`.
  It bound the milestone tool and tests at SHA-256
  `ab913e1e3f4308368abfdc95f5049e19a74919a1f82d51f5ba1bfb7772cf7dd1`
  and `90d65e3b068606a32095bac51d21a7479fdebb1cd5741cdf76443ab9fc21347a`,
  and the hierarchy checker and tests at SHA-256
  `f45b487e0d2096fe667296f3297a22e176de46adc940c42e5b2509dccfa26ed7`
  and `78d349283102c325bf09ed54282f2efc6bf63b887e83dbaf7326d66212e85284`.
  It found reparsed and symlink-following hierarchy inputs, swallowed read
  failures, surplus CLI arguments, malformed milestone child identities,
  invalid epic-title shapes, and an incomplete cross-milestone zero-write
  oracle. That snapshot is superseded: the repaired milestone and hierarchy
  surfaces received replacement bounded `GO` reviews whose exact bindings and
  behavior evidence are recorded in O-05, O-08, and O-18. Neither bounded
  review substitutes for the final exact-head PR review or CI.

## Historical bounded-review evidence

Entries below preserve review records produced before the final repair overlay.
They were compared with `f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba` and
remain useful only for the exact bytes named by each record. Any path changed
after its recorded hash or scope is superseded evidence, even where the older
text says “current.” Rejected intermediate snapshots are retained only when
explicitly labeled superseded. None is the final exact-head PR review, CI/CD
evidence, or deployment evidence. PR #511 must publish one
new immutable-head review and CI readback for the complete delivered tree.

- The Nomad renderer received `GO` at scope digest
  `74c7f6711458256a688d913048f26f92d97d0d1bfb9fa106308b59324916b7d6`.
  SHA-256 values are
  `a1f837650e5672eebee7fab8bac4a11a9708404129d89a1a143b3f129d29f13f`
  for `scripts/render_nomad_configs.py` and
  `d2d0e4136d7990294a4bf0f9e173f93ab79b9efbb6b54c872ec94d6537760216`
  for its tests. Bash 3 and Bash 5 each passed 25 of 25 checks; syntax,
  ShellCheck, and scoped diff checks passed. Real Nomad or `hclfmt` execution
  remains an exact-head Linux CI obligation.
- Hook propagation received `GO`. No verified scope digest was retained, so
  none is invented here. SHA-256 values are
  `97eb978db8745aa7c4279a725ca7b7ebe56fa5631b9185d900ba4244005ac047`
  for `tools/propagate-pre-commit-hooks.sh` and
  `e3c229d2a48af4a7ee24794e454086358b94e8d57ecd9e89d18d1560904ac875`
  for its tests. Bash 3 and Bash 5 each passed 31 of 31 checks; syntax,
  ShellCheck, and scoped diff checks passed. The real unprivileged Linux
  `O_TMPFILE` path remains CI-only.
- The retained bounded-review record for the report publishers reports `GO` at
  scope digest
  `982d2bf7f9d1d864c2b66f2b1855f35cfc03cce2e6082ada5891118416299fa3`.
  This ledger records that supplied review result; it is not the final
  exact-head PR review or CI evidence. Current SHA-256 values are
  `b3212e5c4459a1b626a9784b0d9fb6ec59d2274dde2b3907f443499559d86c24`
  for `scripts/safe_report_publish.py`,
  `b7ff4b648389f3b36919d4ca0c71030e495cb7575be0ec94217591f9b0eb92b4`
  for `scripts/ecosystem-health.sh`,
  `27f531b685b93deef3f60a586772b9c15e661383067a1eef17988eb202baf915`
  for `scripts/gen-ecosystem-table.sh`,
  `a7db0f3bb8b6342f55956e59b86540d71d65cf30fef50d4e7d58fb13db7b84ee`
  for the health tests, and
  `a93a50db3a78faec636755f4238aa098a76c6488504f8e11486fcaadd1a004ca`
  for the table tests. The retained test record reports 15 of 15 health checks
  and 19 of 19 table checks under Bash 3 and Bash 5, including bounded FIFO
  rejection, Markdown escaping, no temporary-path disclosure, hardlink and
  symlink rejection, same-sink rejection, parent/name swaps, and process
  isolation.
- The current seven-file readiness and timeout repair received independent
  `GO` at staged scope digest
  `9032918aceda5b9ff49171797bdc78d76526a58a6f03a5ab1f4236ae84ac8c91`.
  SHA-256 values are `1e0a0083117dd98e60db8a6fb06fb3e2f5accbbd124508b379614c39235d0fc4`
  for `e2e/lib/common.sh`,
  `692fe9d5e0a12928d680b71c88f2a4b409b6bbf53e71d7af04585eaaace1ff18`
  for `e2e/run-hello-world.sh`,
  `304f6e6c0b2c0be3f8ab7bdae0c1697658d08603384588de2565df57c0efa41b`
  for `e2e/start-stack.sh`,
  `fb6d90d89351d6bb22843e6cdbed61a3f196915318610b6981d886971306cd00`
  for `e2e/doctor.sh`, and `0f1aa7f05c85e1983b900314ed08f082a970ec29438345193f03f1c239d1914f`,
  `e65bddd3cb8a24115f38b221b539a22edfd3acc01340d849923334c6815b695f`,
  and `28d86c70f5248adbb24b14d67ff444ab44d8b1c5edb543110a1397a741e1c125`
  for their three focused test files. Bash 3 and Bash 5 each passed 25 of 25
  hello-world, 52 of 52 stack, 62 of 62 doctor, and 32 of 32 common-helper
  checks. Mutation runs rejected task `30→300`, service `60→30/600`, and
  Grafana `30→60` budget regressions. No live Podman, Tailscale, or service
  readiness result is claimed; exact-head Linux CI remains authoritative.
- The retained bounded-review record for the runtime-audit repairs reports
  `GO` for maintained HCL parsing, fail-closed tooling setup, NATS capture, and
  frozen dispatch-schema validation. Only the scope-digest prefix `3596a0fc`
  remains in retained context, so this ledger does not invent or promote a
  full digest. That older scope does not bind the subsequently changed
  `justfile` or configuration-validator tests. Current SHA-256 values for the
  unchanged paths are
  `ca8de6f381421cd7ca36c13b20b8c580cf217fec608589acf41e4143fe18c3ee`
  for `scripts/validate_nomad_config.py`,
  `8ad594710125c39c127e0442cf2e373214ff19432ac8d00e2be352e9fd51238c`
  for `pixi.toml`,
  `7b8122e25f9f5a7020810176cc7b1d2760794cf8e0d3c6b691c7428e75972e03`
  for `pixi.lock`,
  `7e34fa44e381300feda5af0714c2b37cceeac05b4c190e365f3b733aa5c378a0`
  for `scripts/install/60-claude-tooling.sh`,
  `9615d8e709a1eeb77e50e0623b64803276a7f55592d35b1c1ee1f7f1b2aca333`
  for its tests,
  `72b3219db16e3ce46771c85dd234b5c6984563a0f7844b0fa46aaf8ded0bdc90`
  for `e2e/capture-nats-event.py`,
  `690a31b57ad37968e354a71b010050d2411d728db6d7befb047eb23f60af6dd6`
  for its tests,
  `06dddaf5eeb8ef07e08db13598b0f60af3757fa0f8f5117b77a45fe59a4dc89b`
  for `configs/schemas/dispatch-envelope.hi-v1.schema.json`, and
  `9589591772bdcc17a077fbe88c44eb04692162814817bae7abf5478780359bcd`
  for its tests. The retained test record reports fail-closed malformed and
  unavailable-parser cases, 84 of 84 tooling checks under Bash 3 and Bash 5,
  4 of 4 NATS-capture checks, 9 of 9 schema checks plus a tamper negative, and
  a successful Pixi 0.67.2 lock check. This macOS host cannot run the
  Linux-only frozen install, so exact-head Linux CI remains authoritative.
- The current NATS validator and authorization repair received bounded `GO` at
  scope digest
  `b0e4c400f1e058d0294b583280f1f4912decdff816a176f416902fa3ed3fedbb`.
  Current SHA-256 values are
  `d8ff235fd9bea744c4a8b0525e2ebefe880a0c7d80dfba2e6d6b4b5c986bc115`
  for `scripts/validate_nats_config.py`,
  `cd3d291e9fe8667071fc3e567087f6020525d6f92788af943bd7306b7f410a9b`
  for `tools/validate-nats-auth.sh`,
  `a201c90a61729a3d62efe51884ae907b44039e734b3929a202824399f16e0116`
  for its tests,
  `f9ddf1aece8d4f3dc6ff19e077506ed138addd6b1303cd08c5d7a1de927219c9`
  for the configuration-validator tests, and
  `33d030b59d86edae8f930bc2ab6400be3af59ba8c2719ec45d3463e4599eed71`
  for `justfile`. Authorization checks passed 54 of 54 under Bash 3 and Bash 5.
  Configuration checks passed 15 of 16 because the protected canonical leaf
  config remains invalid and requires separate operator approval; that failure
  is unresolved and is not represented as completion.
- The AlexNet C6 repair received `GO` at scope digest
  `cc2e2107adba0f06760c0bcffa9f427ff066e7e484ad4b99798a1f0cfce83153`.
  SHA-256 values are
  `0f95a182bb8db0a6d4d1b56bd3dd5a155efa9df66a6803972a64c2c81e2a999e`
  for `e2e/alexnet-mesh-chaos.sh`,
  `8b89caef9a05cc92aedffc8661220c1140154cf078e04617590de5587cf6b29e`
  for its operations tests,
  `ad0915d73c99c85313e4d913867ec6616326b867c80689f9482b1e01d080990d`
  for the runbook,
  `c444e4f44d10ab84f40e68fb7e5e309e3fe459eb5ae4a6614918518597d40aba`
  for fleet deployment, and
  `3ab64b81063c3c00c2714d9d551b8839ca96fbf90d0eb34f2f593695a65c21df`
  for training. Bash 3 and Bash 5 each passed 102 of 102 operations checks;
  syntax, ShellCheck, and scoped diff checks passed. No live Podman, Tailscale,
  network, or remote mutation was used.
- The current seven-file Athena integration and legacy-harness boundary repair
  received independent `GO` at staged scope digest
  `ade641b6c495ff9c4454ce35fe098467cc2ee81fddf1230a0e9a94aa7e9a1012`;
  its staged binary-diff SHA-256 is
  `f3a3380797f1fabad0e42063b9a58b59007fd5bf55bd9ca5fd02be55973425d9`.
  SHA-256 values are
  `dcc0a414a1b794ba53538f1ba712b31b427af26a97847f6fbb42d66ae86f3951`
  for `e2e/athena_readonly_chain.py`,
  `a2a7a05d38b196e0fa11681726dc2506d84af0479bad3036ad019219baf2cc3b`
  for `e2e/legacy_athena.py`,
  `f630af5a061552f962aac59a7e9558c2d53808ca4ec15f7d81de925fe4f622d5`
  for `e2e/claude-myrmidon.py`,
  `b5cdd06e78e49d3658ef6d1766c0b970b6aacd17c74f12a93b12c9ea7bcaf63c`
  for `e2e/claude-myrmidon-multi.py`,
  `49e428fe992bea0ee2c754bf215bc1f609b98341142e1cb02acaab2f5d855323`
  for the contract tests,
  `6da769b1c5abec21732f8742ede2f76e050206da3d572292aa5661f9aae9cf51`
  for the immutable v0.5.3 fixture, and
  `d3757f12dfbf81132f3b2c0ff23cfa20f34f2db8cfecdeb0412e823a965701f7`
  for its provenance. The contract suite passed 46 of 46 in both embedded-
  fixture and explicit official-root modes; the independent review reran 46 of
  46 in no-environment mode. Process finalization, REST and GraphQL read-only
  guards, exact release binding, compilation, and staged diff checks passed.
  No live service, container, Tailscale, or remote mutation was used.
- Intermediate installer reviews at scope digests
  `14f1af26793da06907e74f022ff1fc23a11fcae3afefe79c54851e4e458f0db3`,
  `0b3c720a28f7cddfc50aa20d373255c1c32ef4442e47b27eb89faf7c7ed9f1be`,
  and `da80240a73e8733e31b652c55c2732e07c9cfd2c4f1ad404b615ce7c6f0d6870`
  returned `NO-GO`; those immutable snapshots are superseded evidence. The
  current installer repair received `GO` at scope digest
  `b9c92af7066745c611d4da113cfe8529ef8dc3dba84c6014316f64c5195768d6`.
  Current SHA-256 values are
  `d025edce4174f0218d21603a25b3a5f50a19877cab4d55f12ff316240f5e6bf8`
  for `scripts/install/dev/80-precommit.sh`,
  `12dd17f472fa2f5e8d210652760655538a2c61efca308e03b36d2c534cba8960`
  for `scripts/install/dev/precommit_hooks.py`, and
  `6e1f0909149ac7e960b41ad31e73ca4af36391b8d10c881504db87b65ec13209`
  for `tests/test-push-signatures.sh`. The focused suite passed 32 of 32 under
  Bash 3 and Bash 5 with the exact pre-commit 3.8 runtime; Linux exact-head CI
  remains authoritative for host-specific execution.
- Proposed ADR-024 and the ADR index received independent `GO`. The ADR
  SHA-256 is
  `f1260738a452860e02b000f5f8535b0afe3cce5fc06ebc39650b842501153fe2`,
  the index SHA-256 is
  `9ccb27812c7a7dbc1a90973cf03d3e723655a157690d2e323039687aad3bd9f7`,
  and the exact staged patch SHA-256 is
  `ad04d0c75670ff82b23406ddd98591e1f2f4f16e82c255e4249778103bb51f9d`.
  The review verified the exact-pinned seven-stream and durable-consumer
  inventory, branch-safe NATS version floors, subject and endpoint denial
  semantics, migration-helper boundary, full RP0/RP1 state comparison, and the
  live-at-pin `loki-bridge` migration-or-proven-retirement disposition. The ADR
  remains Proposed; no canonical config, live broker, credential, or deployment
  change is authorized or claimed.

Portable documentation and YAML validation passed with isolated caches:

```text
git diff --diff-filter=ACMR --name-only -z origin/main -- '*.md' |
  xargs -0 env npm_config_cache=/private/tmp/odysseus-npm-cache \
  npx --yes markdownlint-cli@0.47.0
env UV_CACHE_DIR=/private/tmp/odysseus-uv-cache \
  UV_TOOL_DIR=/private/tmp/odysseus-uv-tools \
  uvx --from yamllint==1.38.0 yamllint -c .yamllint.yml \
  workflows/ configs/ .github/ISSUE_TEMPLATE/
```

The Markdown command exited zero with only an npm engine warning from a
transitive dependency. The YAML command exited zero with only a uv
version-normalization warning. Exact-head CI remains authoritative.

Fresh hidden, tracked-tree, loader, packager, generator, test, and
organization-wide searches closed the deletion-search gap for the eleven
removed assets recorded in O-20, O-27, O-40, and O-45. They found no live
execution consumer.
The remaining organization results are base-revision Odysseus references,
issue and pull-request task history (including open records that must be
reconciled or rebased), or frozen Mnemosyne knowledge/history that this
migration must not edit. Those references are evidence, not live execution
consumers.

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
| O-01 | Two Proposed ADRs used number 009. Renumber the Nomad-deferral proposal to ADR-021 and update its live references; retain NATS authentication as ADR-009. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Do not edit Accepted ADR bodies. | Implemented by PR #511; both affected ADRs retain their recorded status. | Tracked/hidden reference search, ADR status check, Markdown validation, and PR diff. |
| O-02 | Add Proposed ADR-022, “Layered, Provider-Neutral Agent Instructions,” referencing ADR-020 and existing mesh/task schemas rather than duplicating them. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Proposal only; dependent PRs wait for human acceptance. | Implemented in PR #511; acceptance pending. | Human decision plus exact accepted revision before downstream work starts. |
| O-03 | Repair incomplete or inaccurate ADR indexes and current-versus-proposed claims. Keep evidence integrity as direct repository policy without representing Proposed ADR-014 as Accepted. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Accepted ADRs stay byte-unchanged. | Implemented by PR #511; direct repository policy and ADR status remain distinct. | Header-to-index comparison, protected-file diff, link and Markdown checks. |
| O-04 | Slim the root contract and correct repository counts, knowledge fallback, historical ai-maestro wording, host-mount claims, runbooks, onboarding, and `just`/`pixi` routing. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve operational safety and evidence policy. | The concise root contract and exact-pin documentation repairs are present. ADR-022 remains Proposed; exact-head PR review and CI are pending. | The earlier selected-document `GO` bound digest `8b6f16b5155ceb2dd816d487844b2195cb1b5e07af3cc7799b457bdb29c6e92e`, but later edits changed the listed paths and a later `b8071769...` receipt lacks an exact retained path manifest. Final current-scope review is therefore still required; no stale digest is promoted. |
| O-05 | Make the checked-in Telemachy workflow manifests canonical for future M0–M6 task descriptions; make milestone issue generation resolve descriptions by exact task subject instead of retaining duplicate prompt prose. Keep the M4.8 operator gate in schema-valid workflow metadata and do not rewrite closed issue bodies. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Closed issues are immutable historical records; existing milestone IDs, repositories, subjects, dependency edges, defaults, and `hi/v1` fields stay unchanged. | All 40 dispatchable M1–M6 descriptions resolve from workflow tasks, M4.8 resolves from workflow metadata, and the exact repaired milestone snapshot received independent `GO`; exact-head PR review and CI remain pending. | Scope `bc84224de88b7b66f3f1460012cf4795f695844c2587fa762f2031402cf2c863`; tool `883ce7ea1465b4a9857d3e159fc3337bce5404741c0000e6f91094f90422e8cf`; tests `92966c40f923e3f43bfda1feca8dff60907b72faf4b82788f913a9f2f007b469`; 68 of 68 checks passed, including exact historical-source negative oracles. Exact-head Linux CI remains authoritative. |
| O-06 | Update issue and PR templates to express outcome, scope, allowed effects, relevant checks, completion, and stopping conditions; remove blanket full-suite, fixed review-wave, and submodule-pin suggestions. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Template changes grant no new remote-write or pin authority. | The main PR template, three issue templates, and six Atlas milestone PR templates are updated in PR #511. Exact-head review and CI are pending. | Markdown lint, frontmatter parsing, link-path validation, and `git diff --check` passed locally; rendered GitHub presentation and current-head CI remain required. |
| O-07 | Install only Athena's plugin skills, use `.agent_brain/knowledge`, and remove duplicate Hephaestus skill installation. Keep the documented check-only mode read-only: it must not create directories, edit settings, or update the knowledge checkout. In install mode, report the post-repair result rather than retaining a pre-repair failure or emitting false success after a write error. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve plugin identity `athena@Athena`; do not mutate user caches as proof. Network and filesystem writes require explicit install mode. Reject symlinked or non-regular settings paths before reading, backup, Git, or reconciliation. | Installer changes and isolated-home regression tests are present in PR #511. This does not claim an Athena release or a real user-cache mutation. The retained bounded-review record reports `GO`; final exact-head review, release resolution, and CI are still pending. | The Claude-tooling suite passed 84 of 84 focused cases under Bash 3 and Bash 5. SHA-256 values are `7e34fa44e381300feda5af0714c2b37cceeac05b4c190e365f3b733aa5c378a0` for the installer and `9615d8e709a1eeb77e50e0623b64803276a7f55592d35b1c1ee1f7f1b2aca333` for its tests; syntax, ShellCheck, and scoped diff checks passed. This does not replace the exact-head Linux lane or prove a live user-cache mutation. |
| O-08 | Make hierarchy sync report unavailable/failure when submodules are absent and expose the documented `just` entry point. Reject incomplete, ambiguous, symlinked, replaced, or unreadable inventories instead of silently ignoring inputs, reparsing mutable paths, or letting duplicate names overwrite one another. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | No false-green result. | The checker emits unavailable/unknown with exit 2 when safe comparison inputs are absent, rejects unsafe inventories, and exposes `just check-hierarchy-sync`. The exact repaired snapshot received independent `GO`; exact-head review and CI are pending. | Scope `9e3a24a888b57f33df814aa58983a1464b02b7c23c16c384228c8dbe28005fdf`; checker `b250f2eacca6f895a35ffa20c3632518f3f115d8d0da64fbb93698e9d88f01df`; tests `92ab310ed57955c025de6179f0d87bb32ad1ed5bc3b8912fefc3cd96f8a664cb`; Bash 3 and Bash 5 each passed 45 of 45. The uninitialized worktree correctly remains unavailable, not passing. |
| O-09 | While legacy harnesses remain, fence issue text, reject malformed routing rather than fan out to all repositories, require exact verdict schemas, propagate invocation failures, enforce protected scopes, and emit completion only after verified terminal evidence. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve tool scopes, container isolation, timeouts, protected paths, and the later exact-pin retirement gate. | The current seven-file Athena integration and harness boundary received independent `GO` at scope digest `ade641b6c495ff9c4454ce35fe098467cc2ee81fddf1230a0e9a94aa7e9a1012`; binary diff `f3a3380797f1fabad0e42063b9a58b59007fd5bf55bd9ca5fd02be55973425d9`. The harness remains live; no live-service, E2E, CI, or retirement result is claimed. | The contract suite passed 46 of 46 in embedded-fixture and explicit official-root modes; an independent rerun passed 46 of 46 in no-environment mode. Current hashes and fixture provenance are recorded above. Darwin descriptor limitations and all live/container behavior remain exact-head Linux CI obligations; Tailscale is unavailable locally. |
| O-10 | Open issue #478 conflicts with this modernization by requiring the obsolete 91-principle mirror and `@AGENTS.md` pointer. Reconcile or retire it only after ADR-022 acceptance. | Odysseus / TBD | Do not edit the issue or associated workflows in Wave 0; workflow consequences require human approval. | Live conflict recorded; no mutation authorized. | Fresh issue readback, dependency decision, and approval record. |
| O-11 | Remove editorial workflow gates only under the protected-workflow process. Move any live inline prompt into versioned resources. | Odysseus / TBD | `.github/workflows` requires human review. | Wave 6 approval gate. | Classified diff and retained-gate checklist. |
| O-12 | Update submodule pins only once all child PRs and provider releases land. | Odysseus / TBD | `.gitmodules` and gitlinks require explicit integration approval. | Wave 6; not authorized. | Exact child release/merge SHAs and integration readback. |
| O-13 | On exact integrated pins, prove routing, three-heavy-worker concurrency, timeouts, isolation, tool scopes, restart/retry, issue binding, PR lifecycle, and truthful receipts; run one real ADR-020 M4 mesh-only dogfood issue. Retire both legacy harnesses only in a later separate reviewed PR after proof passes, preserving Hephaestus single-device fallback. | Odysseus and mesh owners / TBD | Real operational run and legacy deletion require human-reviewed boundaries; raw evidence is immutable. | Wave 7; blocked on integration. | Actual terminal receipts or truthful failure; unit/simulation evidence alone is insufficient. |
| O-14 | Correct proposal-era authority wording across milestone task sources, generation, tooling comments, ADR-014 context, and runbooks without changing the `hi/v1` schema, existing milestone identities, or dependency edges; add M4.8 as the explicit exact-pin dogfood closure task. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | `hi/v1` fields, enums, subjects, existing milestone identities and dependency edges, and mesh runtime defaults remain unchanged. M4.8 is the sole milestone addition: an operator-held gate with six repository-qualified verification prerequisites and no parser dependency edges. | The documentation and task-source corrections are present in PR #511. `configs/schemas/dispatch-envelope.hi-v1.schema.json` is byte-for-byte identical to base `ccc6c15`; final exact-pin documentation review and CI are pending. | The restored schema has Git blob `8c2fdeb901a46792cb92ad69de6139d53f17e14e` and SHA-256 `06dddaf5eeb8ef07e08db13598b0f60af3757fa0f8f5117b77a45fe59a4dc89b`, identical to the base object. Its test has SHA-256 `9589591772bdcc17a077fbe88c44eb04692162814817bae7abf5478780359bcd` and passed 9 of 9 checks plus a tamper negative. Milestone parser/generator tests, documentation checks, and a final exact-head schema diff remain required. |
| O-15 | Open PR #498 and its stacked PRs #503, #505, and #507 carry a different Proposed ADR-021 for Fleet execution. Keep ADR-021 assigned to the Nomad-deferral proposal in this approved modernization plan; reserve the next unused number, ADR-023, for the Fleet proposal. The Fleet stack must rebase after PR #511 lands, rename the ADR and all live references, and pass the unique-number check before merge. | Odysseus / PRs [#498](https://github.com/HomericIntelligence/Odysseus/pull/498), [#503](https://github.com/HomericIntelligence/Odysseus/pull/503), [#505](https://github.com/HomericIntelligence/Odysseus/pull/505), and [#507](https://github.com/HomericIntelligence/Odysseus/pull/507) | The superseded PR #509 did not mutate or merge the Fleet stack; PR #511 does not change accepted ADR bodies. | Collision recorded from live PR inspection; Fleet renumber/rebase remains required before that stack can merge. | All-state PR search, exact-head/blob readback, post-rebase unique-number check, and updated ADR index/reference search. |
| O-16 | The current milestone checklist and pinned Agamemnon planning parser identify issues only as repository-blind `#N` values. Keep existing machine checklist grammar unchanged; render M4.8 outside that parser surface as an operator-held gate with repository-qualified evidence links. Add repository-aware identity and dependency parsing only in a coordinated producer/Agamemnon change after ADR-022 acceptance. | Odysseus and Agamemnon / TBD | Preserve current `hi/v1` fields and exact-pin parser behavior; do not claim automated cross-repository dependency enforcement. | Wave 3; blocked on ADR-022 acceptance and a consumer compatibility plan. | Exact-pin parser fixtures for duplicate cross-repository issue numbers, producer/consumer compatibility tests, and one real M4 proof. |
| O-17 | PR #508 contains a malformed immutable Athena round-2 carrier and cannot support verified review delivery. Preserve its review evidence. PR #509 superseded it at the same corrected source lineage and started a new target-bound exchange. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511), superseding [PR #508](https://github.com/HomericIntelligence/Odysseus/pull/508) | Do not edit, delete, dismiss, or reuse the malformed review record. Do not merge PR #508. | Historical replacement PR #509 was established, and PR #508 closed unmerged after exact replacement readback. PR #509 is now superseded by PR #511 because its retained review schema is incompatible with Athena 0.5.3. | Exact target, base, head, body, branch, and review-history readback for both historical pull requests and PR #511. |
| O-18 | Milestone registration treated deterministic public body markers as ownership, allowed a marked issue to hide a same-title duplicate, skipped child verification after finding an epic, followed workflow symlinks, accepted wrong YAML scalar types through coercion, admitted malformed epic titles and child IDs, and lacked a global epic/child title namespace. Require exact canonical bodies, globally unambiguous and milestone-qualified identity, regular no-follow workflow inputs, declared authored types, a dedicated non-state operator-gate label, complete all-milestone read-only preflight before writes, strict intake state for partial creation, and lifecycle-aware validation for registered epics against the pinned Hephaestus issue-label contract. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Never adopt or relabel an untrusted issue, and never load a workflow through a symlink. Existing issue bodies and labels are not mutated; issue/PR state ownership and mesh defaults remain unchanged. | Implemented and independently reviewed `GO`; exact-head PR review and CI remain pending. | Scope `bc84224de88b7b66f3f1460012cf4795f695844c2587fa762f2031402cf2c863`; tool `883ce7ea1465b4a9857d3e159fc3337bce5404741c0000e6f91094f90422e8cf`; tests `92966c40f923e3f43bfda1feca8dff60907b72faf4b82788f913a9f2f007b469`; 68 of 68 checks passed across spoof, duplicate, cross-milestone, body-drift, unsafe-path, wrong-type, zero-write, partial-retry, and lifecycle branches. |
| O-19 | The `idempotent-build` job for PR #509 could not initialize its job container on the self-hosted Aeolus runner because `/var/run/docker.sock` was absent. Run [34901052422](https://github.com/HomericIntelligence/Odysseus/actions/runs/34901052422), attempt 2, reproduced the same pre-checkout infrastructure failure. The workflow blob `87f4a08f4906c99d986d34cb4a07731280e783be` was identical at the bound base and head, so the failure was not introduced by that PR diff. | Odysseus runner operator / [issue #432 escalation](https://github.com/HomericIntelligence/Odysseus/issues/432#issuecomment-5671634642) | Do not use Tailscale or attempt host repair from this environment. Any `.github/workflows` workaround requires prior human approval; a failing check cannot be waived or represented as completion. | The historical escalation is recorded. No host repair path is available to this task, no protected workflow edit is approved, and no workaround has been applied. PR #509 remained non-terminal and is now superseded by PR #511. | A runner repair or separately approved workflow change, followed by a successful exact-head `idempotent-build` run and final exact-head review on PR #511, is required before merge. |
| O-20 | Delete the three completed one-shot executables under `scripts/migration/hephaestus-split/` rather than modernize generators that can overwrite current Athena/Hephaestus surfaces, recreate the nonexistent `athena-start` recipe, perform stale plugin registration, or repeat destructive remote-write migrations. No unique current rule requires migration: repository ownership and dependency direction remain in Accepted ADR-016 and current repository contracts, while source provenance remains in Git history, merged PRs #385 and Hephaestus #2063, and the completed runbook. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve Accepted ADR-016, historical commits and PR evidence, the live Athena and Hephaestus repositories, and current release/install contracts. Do not execute the retired remote-write paths. | Verified-dead deletion is present in PR #511. `athena-create.sh` was base blob `13ace58d63f2168bb2f3e5b5c2a091c34d6d5fa7`, SHA-256 `b02f2e389b6ef0e60b83d6d31fd9922a2e47beb2c1c0f6af9e24fb20061ed71c`; `hephaestus-meta-repo-pr.sh` was base blob `b4db864730668c81c600c05e2324eff1209fb14b`, SHA-256 `09afe67ed77aafbc3b1bba2ddf76fa09f75bf60cbd7fa7b1140924d93384e6fa`; `hephaestus-prune-pr.sh` was base blob `a47a18119c0453faba8d67ea8d76e2aca1d011e7`, SHA-256 `4b1c12115a4a64d8fc2a320761bda695feffbb329765199d3d7cba16b645c643`. Exact-head review and CI are pending. | Hidden/no-ignore `rg`, current/base `git grep`, `git ls-files`/`git ls-tree`, loader/packager/generator/workflow/test searches, pinned/current component-tree inspection, Git history, and organization-wide `gh` code/issue/PR searches found no live execution consumer. The only generic consumer was tracked-shell ShellCheck, which automatically drops deleted paths; open PR #498 contains a one-line lint repair to `athena-create.sh`, not a runtime consumer, and must drop it when rebased. |
| O-21 | Repair contributor and hook guidance that recommended `--no-verify`, force-pushing rewritten history, exact one-line `Fixed -` review responses, and unconditional auto-merge. Make signed-commit enforcement real at the pre-push transaction boundary rather than advertising a non-operative pre-commit stage. Require current-head CI, terminal current-head Athena `GO`, resolved review conditions, and a merge method enabled by live repository policy. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Security, size, signature, version, and other hook gates remain executable; documentation does not grant bypass, remote-history rewrite, or merge authority. Never overwrite an unmanaged hook or honor an alternate `core.hooksPath` silently. | Earlier `NO-GO` snapshots are retained above as superseded evidence. The current transactional installer and signature-boundary repair received independent `GO` at scope `b9c92af7066745c611d4da113cfe8529ef8dc3dba84c6014316f64c5195768d6`; exact-head review and CI remain pending. | Wrapper `d025edce4174f0218d21603a25b3a5f50a19877cab4d55f12ff316240f5e6bf8`; helper `12dd17f472fa2f5e8d210652760655538a2c61efca308e03b36d2c534cba8960`; tests `6e1f0909149ac7e960b41ad31e73ca4af36391b8d10c881504db87b65ec13209`; 32 of 32 passed under Bash 3/Python 3.9 and Bash 5/Python 3.14 with exact pre-commit 3.8. |
| O-22 | Remove the broken `mnemosyne-generate-marketplace` and `athena-start` root recipes, describe Mnemosyne as the knowledge backend, and make `athena-bootstrap` call Athena's real pinned bootstrap recipe. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve the public `athena@Athena` identity, the pinned component revisions, and historical walkthrough/runbook evidence. Do not invent a server lifecycle for a plugin distribution. | The repair is present in PR #511. Exact pinned Mnemosyne has no `generate-marketplace` target and exact pinned Athena has no `start` target; both stale root aliases had no live caller. | Exact-pin child-target inventory, hidden/no-ignore local search, organization-wide code/issue/PR search, root `just --summary`/`just --list`, focused retired-recipe absence checks, and `git diff --check`; exact-head CI remains required. |
| O-23 | The checked-in fleet policy and rendered `repo-ruleset-active.json` describe a sole `required-checks-gate`, but a fresh GitHub readback reports that Odysseus ruleset 15556483 instead requires 11 individual GitHub Actions contexts. Treat the live effective ruleset as the merge authority and do not classify skipped or informational checks by the stale desired-state file. | Odysseus ruleset operator / TBD | A ruleset mutation is operational desired state and requires human approval; adding or changing its aggregate workflow also requires protected-workflow approval. Never use the reported repository-role bypass. | Drift recorded; no live ruleset or workflow mutation is authorized in this PR. The legacy harness repair must bind the complete live effective policy at each merge attempt and fail closed on ambiguity or change. | Exact-head ruleset, branch-protection, repository-setting, check-suite app identity, review-thread, mergeability, and merge-method readbacks immediately before merge; separately approved desired-state reconciliation. |
| O-24 | The required integration workflow labels submodule URL reachability as a check but converts every failed `git ls-remote` into `WARN` and returns success. Repair that false-green oracle so unavailable pinned dependencies cannot be reported as a passing reachability check. | Odysseus / TBD | `.github/workflows/_required.yml` cannot be edited without prior human approval. Do not weaken or remove the integration gate. | Verified in the bound workflow blob and classified for Wave 6; no protected-workflow edit is authorized in PR #511. | A RED fixture or deliberately unreachable remote must demonstrate the current false green, followed by an approved workflow repair whose exact-head CI propagates the nonzero result. |
| O-25 | Remove the dead Odysseus `apply-all` wrapper and its live operational claims. The exact pinned Myrmidons commit `16a7ed57bff18af737c0a07f50ddcfd9e163e4f4` exposes validation, packaging, test, lint, hook, and container-CI recipes but no `apply` recipe or equivalent application script, so the root wrapper is guaranteed to fail. Future recovery must use a version-matched Agamemnon reconciler only after live-state inspection and explicit operator approval. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Authored Myrmidons files are not proof of live desired state. Do not apply, hibernate, delete, or otherwise mutate live state from this documentation repair; preserve historical reports and changelog evidence. | The dead recipe and live callers are removed in PR #511. Deployment and recovery routes now fail closed when a compatible reconciler or approval is unavailable; historical analyses remain labeled as historical rather than rewritten. Exact-head review and CI are pending. | Exact gitlink readback; pinned-tree and pinned-`justfile` GitHub readback; hidden/no-ignore and tracked-tree searches; root recipe/list tests; shell syntax and documentation checks; exact-head CI. |
| O-26 | Retire the console's unauthenticated or borrowed-credential NATS watch path until a dedicated least-privilege console identity is approved and configured. Reject watch mode before the Nestor submit write, retain the HTTP-only `--no-watch` submission path, keep Nestor TLS trust separate from NATS trust, and report only the returned intake ID rather than an unevidenced research-pool dispatch. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Do not edit canonical NATS configuration, reuse another service identity, send a remote write merely to discover that watch is unavailable, or claim a live NATS connection or downstream dispatch. | The console watch path and its two root aliases fail closed; the HTTP-only path remains available. The exact repaired scope received independent `GO`; exact-head review and CI are pending. | Scope `48f71431c6e212d71939521502c6c6192bddf6043d3b078d1b4e7c0f1143f835`; source `fdd0663a884a0d27ce74439eb1ca54a1be64e984496519cd958afedec7fd0813`; tests `b96aa1f458530742f29746d2f670eb23a1358ec05d1f7b6c9aa09bd2b4809211`; 18 of 18 passed under Python 3.12, 3.13, and 3.14. |
| O-27 | Retire the unmaintained cross-host and Hermes-hub launch surfaces after exact tracked, hidden, loader, workflow, test, and organization consumer searches. Keep their former executable entry points as explicit no-write unavailable stubs for callers that have not yet migrated; remove the dead Compose/Prometheus assets and root recipes rather than retaining false readiness paths. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Historical reports remain historical evidence. The 783 Mnemosyne knowledge entries and 181 notes are frozen for this migration; a current organization search found one protected knowledge entry plus its notes/history naming the removed cross-host Compose overlay. Its command now fails on the absent file before effects, and this ledger does not claim that frozen guidance was repaired. This removal is not Tailscale or deployment proof and makes no live host change. | The executable assets and recipes are removed; four former launch/run scripts stop with an unavailable explanation before network, container, wait, or Tailscale effects. The protected stale Mnemosyne reference is a disclosed residual routed to future authoring/provenance work, not authorization to edit grandfathered content. Exact-head review and CI remain pending. | The no-write fixtures pass 3 of 3 Hermes-hub/cross-host run cases and 4 of 4 launcher cases. Fresh hidden/no-ignore, tracked-tree, loader, workflow, test, and organization searches found no live consumer. Organization results are the disclosed frozen Mnemosyne material, base-revision files, closed issues, merged PRs, or open PR #498, which must rebase and drop deleted-script edits. Re-run only if the bound base changes. |
| O-28 | Harden the AlexNet deploy, wait, collect, training, chaos, and teardown paths around exact nonempty target sets, one current online address per peer, whole-fleet preflight, exact mutation approval, invocation-unique staging, complete parallel receipts, successful container exits, launch-header-bound fresh results, fail-closed prior state, exact local chaos authority, current-run gate identity, and truthful partial failure. Keep the default chaos proof hermetic and independent of Tailscale, and align the runbook with the executable archive, launcher, approval, diagnostics, and cleanup contract. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Remote deployment, teardown, network chaos, and offline-host chaos remain exact-target operator actions. Protected manual-workflow compatibility grants no default model, topology, or unattended live authority. No live Tailscale or host action is available from this environment. | Script, documentation, and CI-reachable hermetic behavior tests are present in the working tree. The immutable-image and exact-container C6 repair received bounded `GO`; protected workflow callers remain unchanged and need the separately approval-gated repairs in O-42. Exact-head review and CI remain pending. | The C6 review bound scope digest `cc2e2107adba0f06760c0bcffa9f427ff066e7e484ad4b99798a1f0cfce83153`, chaos SHA-256 `0f95a182bb8db0a6d4d1b56bd3dd5a155efa9df66a6803972a64c2c81e2a999e`, and operations-test SHA-256 `8b89caef9a05cc92aedffc8661220c1140154cf078e04617590de5587cf6b29e`. Bash 3 and Bash 5 each passed 102 of 102 operations checks; syntax, ShellCheck, and scoped diff checks passed. These hermetic tests did not invoke Podman, Tailscale, the network, or a live topology. |
| O-29 | The required HCL syntax step reports success when neither Nomad nor `hclfmt` is available, so an unavailable parser can become a passing validation. Require a real parser and propagate its failure. | Odysseus / TBD | `.github/workflows/_required.yml` cannot be edited without prior human approval. Do not remove the HCL gate. | Verified and classified; no protected-workflow edit is authorized. The non-protected validator uses maintained `python-hcl2` 8.1.3 and fails closed when its parser is unavailable. | Validator `ca8de6f381421cd7ca36c13b20b8c580cf217fec608589acf41e4143fe18c3ee`; current combined validator tests `f9ddf1aece8d4f3dc6ff19e077506ed138addd6b1303cd08c5d7a1de927219c9`. The protected workflow still requires approval, a RED fixture, and successful exact-head CI. |
| O-30 | The required Trivy filesystem scan is configured with `exit-code: 0`, so vulnerability findings cannot fail the named security gate. Preserve the scan and make its policy-enforcing result explicit. | Odysseus / TBD | `.github/workflows/_required.yml` cannot be edited without prior human approval. Security gates may not be removed or weakened. | Verified and classified; no protected-workflow edit is authorized in PR #511. | Approved workflow edit, a policy fixture or documented threshold, and exact-head security CI that propagates findings. |
| O-31 | Both canonical Nomad source files still claim that `just render-nomad-configs` writes implicitly to `/etc/nomad.d`, while the repaired recipe requires an explicit new approved output directory and never selects a system path. Correct comments only after operator coordination. | Odysseus / TBD | `configs/nomad/` requires responsible-operator coordination even for comment-only edits. Do not imply deployment authority. | Drift verified; no canonical-config edit is authorized in PR #511. | Operator approval, comment-only diff, parser validation, render behavior tests, and exact-head CI. |
| O-32 | Make the local prerequisite doctor test command usability rather than mere path presence, keep local mode independent of Tailscale, and stop when a packaged Podman user unit is missing instead of synthesizing an untrusted replacement. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Install mode and host service changes remain explicit operator actions. A missing package or unit is a failure, not authority to write user or system service files. | The fail-closed probes and hermetic fixtures received independent `GO` as part of the seven-file network scope. No host package, service, socket, or Tailscale action was performed. | Scope `9032918aceda5b9ff49171797bdc78d76526a58a6f03a5ab1f4236ae84ac8c91`; doctor `fb6d90d89351d6bb22843e6cdbed61a3f196915318610b6981d886971306cd00`; tests `28d86c70f5248adbb24b14d67ff444ab44d8b1c5edb543110a1397a741e1c125`; Bash 3 and Bash 5 each passed 62 of 62. |
| O-33 | Replace stack-readiness false positives with exact required-container and selected-endpoint postconditions. A partial fast path, failed Prometheus reload, unavailable Argus address, or any post-start health failure must return nonzero and withhold “Stack ready.” Publish Prometheus runtime configuration with the owner-private bootstrap and exact readable file postconditions required by the pinned image. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Local Compose effects remain scoped to the selected local stack; the check grants no deployment or cross-host authority. | The current exact Hermes/Argus fast- and terminal-path repair received independent `GO` in the seven-file network scope. No container or live endpoint was exercised locally. | Scope `9032918aceda5b9ff49171797bdc78d76526a58a6f03a5ab1f4236ae84ac8c91`; launcher `304f6e6c0b2c0be3f8ab7bdae0c1697658d08603384588de2565df57c0efa41b`; tests `e65bddd3cb8a24115f38b221b539a22edfd3acc01340d849923334c6815b695f`; Bash 3 and Bash 5 each passed 52 of 52. Live Podman and readiness remain exact-head Linux CI obligations. |
| O-34 | Make hello-world evidence reject zero or malformed NATS message counts, validate returned agent, team, and task identifiers before using them as URL segments, and pass identifiers to Python as data rather than interpolating executable source. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Task and API responses remain untrusted. Tests use fixtures and grant no live NATS or HTTP write authority. | The current bounded transport, evidence, and identifier guards received independent `GO` in the seven-file network scope. No live NATS or Agamemnon request was made. | Scope `9032918aceda5b9ff49171797bdc78d76526a58a6f03a5ab1f4236ae84ac8c91`; common `1e0a0083117dd98e60db8a6fb06fb3e2f5accbbd124508b379614c39235d0fc4`; runner `692fe9d5e0a12928d680b71c88f2a4b409b6bbf53e71d7af04585eaaace1ff18`; common tests `1d4918e1329ed4e293af1196ad5e8951c52d0ee55dbadbb8ffdf67561cb9d95f`; runner tests `0f1aa7f05c85e1983b900314ed08f082a970ec29438345193f03f1c239d1914f`; Bash 3 and Bash 5 passed 32 of 32 and 25 of 25 respectively. |
| O-35 | Make submodule-drift reporting bind one complete direct `.gitmodules` inventory, reject unsafe, duplicate, partial, or unreadable identity and URL data, propagate every Git read failure, avoid network fetch as validation, and publish CI output atomically without following a destination symlink. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | The checker is read-only with respect to repositories and remotes. It does not authorize submodule initialization, fetch, pin changes, or integration. | Additional ancestry, CI-mode, and safe-publication repairs are present in the current installer/drift candidate. Replacement exact-byte review of that combined overlay and exact-head CI are pending. | Candidate SHA-256 values are `c3702e4e61ebd067691d99e028e15311408e0fa1d1a6e215091320fe1c7dc8b7` for `scripts/check-submodule-drift.sh` and `b39544cd0f9757ea9038109d327a7486292af2122fbb9830ee3c6b4424fbcc14` for its tests. No remote reachability result is claimed, and these candidate hashes are not a replacement review verdict. |
| O-36 | Make the code-quality probe validate a unique safe repository inventory and publish its report only through direct, atomic output paths; malformed, duplicate, or symlinked destinations must fail rather than create a partial or redirected report. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | GitHub responses and output paths remain untrusted. The local fixtures do not prove current organization state. | The fail-closed probe and regression fixtures are present in the working tree. Exact-head review and CI remain pending. | The current focused suite passes 42 of 42 checks. Current SHA-256 values are `6d3bcf90e4c92848ff479a976ca06ac65a18ea9ed6000970a63fdb49ee48d1e7` for `tools/probe-code-quality.sh` and `8548e474823130e1240b62d1b3625642d0e7c7a81d0aad430236c8adf21b0a23` for its tests. Exact-head CI and any future fresh remote probe remain separate evidence. |
| O-37 | Make the ecosystem table and health reporters reject unsafe or incomplete submodule inventories and malformed or truncated API data, bind the reported default branch and commit, escape untrusted Markdown fields, and publish or inject output through descriptor-bound, no-clobber operations that reject hardlinks, replaced parents, same sinks, and unsafe cleanup. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Remote metadata and check names are untrusted data. Report generation is not proof that any remote check or repository is healthy. | The retained bounded-review record for the final reporter repairs and hermetic fixtures reports `GO` at scope digest `982d2bf7f9d1d864c2b66f2b1855f35cfc03cce2e6082ada5891118416299fa3`. No fresh remote health claim is made by these local tests. Exact-head review and CI remain pending. | The retained test record reports 19 of 19 table checks and 15 of 15 health checks under Bash 3 and Bash 5. SHA-256 values are `27f531b685b93deef3f60a586772b9c15e661383067a1eef17988eb202baf915` and `a93a50db3a78faec636755f4238aa098a76c6488504f8e11486fcaadd1a004ca` for the generator and tests, `b7ff4b648389f3b36919d4ca0c71030e495cb7575be0ec94217591f9b0eb92b4` and `a7db0f3bb8b6342f55956e59b86540d71d65cf30fef50d4e7d58fb13db7b84ee` for the health reporter and tests, and `b3212e5c4459a1b626a9784b0d9fb6ec59d2274dde2b3907f443499559d86c24` for the safe publisher. Exact-head CI remains required. |
| O-38 | Make pre-commit hook propagation fail closed for incomplete or unsafe submodule inventories and Git administration paths, avoid partial-fleet writes, and publish direct regular executable hook bytes atomically without clobbering a third-party concurrent state. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Git hook installation is a local mutation. It must not follow symlinks, overwrite unmanaged content, or represent incomplete coverage as success. | The concurrent-install and adversarial path-race repairs received bounded `GO`. No verified scope digest was retained, so this ledger does not invent one. Exact-head review and CI remain pending. | Bash 3 and Bash 5 each passed 31 of 31 checks; syntax, ShellCheck, and scoped diff checks passed. SHA-256 values are `97eb978db8745aa7c4279a725ca7b7ebe56fa5631b9185d900ba4244005ac047` for `tools/propagate-pre-commit-hooks.sh` and `e3c229d2a48af4a7ee24794e454086358b94e8d57ecd9e89d18d1560904ac875` for its tests. The real unprivileged Linux `O_TMPFILE` path remains exact-head CI evidence. |
| O-39 | Make the root pre-commit size gate inspect the staged Git blob rather than mutable worktree bytes, allow the tracked `.env.example` template while still rejecting real dotenv and credential paths (including `*.key` suffixes), inspect all three merge-conflict markers including native hooks, and make test-script lint enumerate one checked tracked inventory rather than silently treating a failed or incomplete filesystem search as “nothing to lint.” | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Hook and lint failures must be repaired, not bypassed. Gitlinks remain outside ordinary blob-size inspection; unreadable staged objects fail closed. The `.env.example` exception does not apply to `.env`, `.env.local`, or a file below `secrets/`. | The hook-selection and staged-content evidence is separate from the later fail-closed lint repair. The lint scope received `GO` at `7989df97f609ff4bfd63870ebbdb447a7896a8bcdebeae45d418f676c4721135`; the signed pre-push transaction guard is O-21. | Lint source `ceab61480d7ffc44e346c208befa620067adf0f2fc5ec681f2c7e5ec1342da0c`; lint tests `00aa4d8ad6eb8e584daef2a80f95fb65e45380a459e5e4193c906de1d9eb1a74`; 14 of 14 focused and 41 of 41 full checks passed under Bash 3 and Bash 5. The current pre-commit hook is `d67474150b46ae1a2cafacb28f13aa01808c4df0cfc37bcf9bd5e3431c00901a`; its staged-content suite passed 11 of 11. |
| O-40 | Delete three verified-dead local assets instead of preserving misleading one-shot or merge paths: `e2e/test-task-01b925cd.sh`, `e2e/hermes-fleet-preflight-fix.sh`, and `scripts/git/safe-merge.sh`. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve Git history and issue/PR evidence. Deletion does not authorize replaying their effects or removing similarly named historical evidence. | The three deletions are present in the working tree. Their base SHA-256 values are `7eb9467352380f887971b873896505b9abde4ecb8f6da405c3a8fe7ca1061f45`, `19b58e4903dd52e820a7c3da824ff4410d32dcb4f66b2d3d799b19b1d7de2ae6`, and `b8ad4caab0052694398712cc42db026be26bec95dacfff9cbfe39892ff4c51fb`. | Fresh hidden, tracked-tree, loader, generator, workflow, test, and organization searches found no live execution consumer. Remaining results are task history, including open issue #488, not executable consumers; generic tracked-script lint drops deleted paths automatically. Re-run only if the bound base changes, then require exact-head review and CI. |
| O-41 | Rewrite the WSL2 rootless-Podman runbook to separate read-only diagnosis from host mutation, distinguish missing packages or units from inactive services, and require exact operator approval, backup, verification, and rollback for `/etc/wsl.conf`, WSL shutdown, socket enablement, and linger. Remove the false rootlessport and generic host-network workaround. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | The runbook grants no host mutation, production deployment, cross-distribution shutdown, or Tailscale authority. Missing Podman units require supported package repair or separately reviewed installation. | The documentation repair is present in the working tree. No WSL, systemd, Podman, or Tailscale action was performed. Exact-head review and CI remain pending. | Current SHA-256 is `7ff586584ad9f75025fdfe44b5c61005259e20e30e746af914d85b4fb0425033`. Markdown/link checks and final exact-head CI remain required. |
| O-42 | Update the protected AlexNet smoke caller to pass the exact requested fleet through `ALEXNET_DEPLOY_APPROVED_FLEET` and `ALEXNET_TEARDOWN_APPROVED_FLEET` and remove the legacy broad `FORCE=1` bypass. Update the protected chaos caller to require an exact approved local host, compare it with `hostname`, pass `ALEXNET_CHAOS_APPROVED_HOST`, and require explicit network/offline-host approvals if those live branches remain. | Odysseus / TBD | `.github/workflows/alexnet-mesh-smoke.yml` and `.github/workflows/alexnet-mesh-chaos.yml` require prior human approval. Remote deployment, teardown, and non-hermetic chaos remain operator actions. | The script contract and hermetic default are repaired in O-28, but the protected callers are byte-unchanged from the bound base. No protected edit or live fleet action is authorized in PR #511. | Human approval, exact workflow diff, script/workflow interface fixtures, a hermetic exact-head CI pass, and separately authorized live evidence for any retained remote branch. Tailscale is not available from this environment. |
| O-43 | Repair the remaining protected CI false greens: the purported Markdown parse check accepts permissive rendering as structural validity, and the optional Claude-read-permissions job reports “Preflight OK” when its verifier is absent. Retain real Markdown lint, compatibility-pointer, schema, parser, security, and behavior gates; remove obsolete agent-editorial validation rather than replacing it with prose snapshots. | Odysseus / TBD | `.github/workflows/_required.yml` and `.github/workflows/ci.yml` require prior human approval. O-19, O-24, O-29, and O-30 record the separate runner, reachability, HCL-parser, and Trivy failures. | Findings are verified in protected files that remain byte-unchanged from the bound base. No workflow edit, runner workaround, or waiver is authorized in PR #511. | Human approval, RED fixtures proving each current false green, a classified workflow diff retaining non-editorial gates, and successful exact-head CI. The Aeolus container-start failure in O-19 must still be repaired by the runner operator or a separately approved workflow change. |
| O-44 | Render the canonical Nomad pair only into one explicit, empty, owner-private directory whose exact device/inode receipt the operator approved. Require canonical literal IPv4 values, one bound read of each direct source, a real HCL parser, and no-clobber publication with complete rollback on failure. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Rendering grants no authority to select or mutate `/etc/nomad.d`; canonical source comments remain separately protected by O-31. | The renderer and hermetic fixtures received bounded `GO` at scope digest `74c7f6711458256a688d913048f26f92d97d0d1bfb9fa106308b59324916b7d6`. Exact-head review and CI remain pending. | Bash 3 and Bash 5 each passed 25 of 25 checks; syntax, ShellCheck, and scoped diff checks passed. SHA-256 values are `a1f837650e5672eebee7fab8bac4a11a9708404129d89a1a143b3f129d29f13f` for the renderer and `d2d0e4136d7990294a4bf0f9e173f93ab79b9efbb6b54c872ec94d6537760216` for its tests. Real Nomad or `hclfmt` parsing remains exact-head Linux CI evidence. |
| O-45 | Delete the completed one-shot repository-rename tools `tools/apply-odysseus-rename.sh` and `tools/github/rename-repo.sh`; preserve their historical runbook, commits, issues, and pull requests rather than retaining executable remote-write paths. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Git history and historical evidence remain intact. The deletion grants no repository-rename authority. | Both deletions are present in the working tree. Base SHA-256 values are `699b450c2f10040926869a8b16b77b3de99d09f98c4ce2e21d0e134c9b10cf5b` and `b9d715535fa8d63ebda2d0c3a04ba6032e7e48c9fdf3f297bde7caea05214c7a`. | Fresh hidden, tracked-tree, loader, generator, workflow, test, and organization searches found no live execution consumer. Remaining references are base revisions, the historical rename runbook, merged pull requests, or open PR #498, which must rebase. Re-run only if the bound base changes, then require exact-head review and CI. |
| O-46 | Make Grafana credential validation reject unresolved, default, malformed, symlinked, or unreadable secret sources rather than reporting a usable deployment. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Validation grants no credential read, generation, deployment, or rotation authority. | The retained bounded review reports `GO`; its exact scope manifest is not retained, so the `fb4bbffc...` prefix is not promoted to a full digest. Exact-head review and CI remain pending. | Current validator SHA-256 `5a61539a8e7982de600662b0d096872e2b901dcf6443a2e64be8e0dab214dd29`; only staged-diff prefix `654f7948...` remains in retained context; 12 of 12 focused checks passed. |
| O-47 | Make IPC startup and teardown bind exact owned processes and resources, with fail-closed cleanup and no broad or identity-ambiguous deletion. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Cleanup may affect only invocation-owned local resources; it grants no fleet, remote-host, or production authority. | The repaired scripts and tests have the recorded content hashes, but no verified review scope digest or path manifest was retained. Exact-head review and CI remain pending. | IPC source `225496f00e73144422fd6c7d955147879035d1a0fd420a7861278cd405c3b350`; teardown `490a1d2141451dd1d679ca03e219123fa5b0ef3acc1162ba5e033493345d4066`; tests `425684d96bb035a2041866cfcd046b1d564782158d8b5a0622e8857d17851d12` and `60a9fbf6cfbc210905c210c18d1ba2379c5ac1931f5030e68d539895098410e2`. No live container proof is claimed. |
| O-48 | Make Compose and image validation use maintained parsers, exact pinned-image rules, and fail-closed contract tests without treating unavailable tooling or unrelated images as success. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Preserve schema, image provenance, and security gates; no image pull or deployment authority. | Bounded review records report `GO`; retained scope prefixes are `b61bd674...` and `32c1c708...`, but their exact manifests are not reconstructed here. Exact-head review and CI remain pending. | Compose validator `07234d330730801b05ae0af8c6b4f012a0682ecaa8ab9c23bb2947ba17c396ae`; image checker `b8dac8bd5cb1ee4bec4f9ef2f5a294f4984e9ba2e4bc41dc4ce9c4cc9e6f363f`; contract tests `4ff4af0dec7ba6c0cac3b216b921a0bf95659ea80835cc6322675e0e5ee484c4`; 7 of 7 passed. |
| O-49 | Make NATS config and authorization validation use the real parser, fail closed on unavailable or invalid syntax, and test exact authentication/permission boundaries. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Canonical NATS config remains protected; a validator failure does not authorize editing or deployment. | The validator repair received bounded `GO` at scope `b0e4c400f1e058d0294b583280f1f4912decdff816a176f416902fa3ed3fedbb`. Authorization passed 54 of 54; configuration passed 15 of 16 because the protected leaf config is invalid. That failure remains unresolved pending operator approval. | Current hashes: parser `d8ff235fd9bea744c4a8b0525e2ebefe880a0c7d80dfba2e6d6b4b5c986bc115`; wrapper `cd3d291e9fe8667071fc3e567087f6020525d6f92788af943bd7306b7f410a9b`; auth tests `a201c90a61729a3d62efe51884ae907b44039e734b3929a202824399f16e0116`; config tests `f9ddf1aece8d4f3dc6ff19e077506ed138addd6b1303cd08c5d7a1de927219c9`; `justfile` `33d030b59d86edae8f930bc2ab6400be3af59ba8c2719ec45d3463e4599eed71`. |
| O-50 | Add Proposed ADR-024 for one hub-owned `HOMERIC` application account, per-role authorization, exact stream/consumer migration, branch-safe NATS releases, and explicit live-state/rollback gates. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | The ADR is Proposed only. Canonical config, credentials, live broker state, and deployment remain separately approval-gated. | Independent exact review returned `GO`; no live-state or deployment claim was made. | ADR `f1260738a452860e02b000f5f8535b0afe3cce5fc06ebc39650b842501153fe2`; index `9ccb27812c7a7dbc1a90973cf03d3e723655a157690d2e323039687aad3bd9f7`; staged patch `ad04d0c75670ff82b23406ddd98591e1f2f4f16e82c255e4249778103bb51f9d`. |
| O-51 | Make the frozen dispatch-envelope test exercise real JSON Schema formats and remain reachable from a required entry point. Lock the maintained validator and RFC 3339 dependencies rather than treating unknown UUID or date-time formats as valid. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | The `hi/v1` schema remains byte-identical to the bound base; this repair changes only validation evidence and dependency reachability. | The portable focused suite passes 12 of 12, including invalid UUID and date-time negatives. Exact-head Linux dependency installation and CI remain pending. | Frozen-schema hash comparison, `FormatChecker` negatives, lock-file consistency, required-recipe reachability, and exact-head CI. |
| O-52 | Provision the NATS syntax parser from one content-pinned official release when it is unavailable, and use the same exact parser contract in the standalone authorization suite. The current validation pin is 2.10.22, not the unaccepted ADR-024 candidate release. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Provisioning selects no deployed broker version and grants no authority to edit `configs/nats/`. The canonical leaf configuration still contains syntax rejected by the real parser. | Provisioning tests pass 5 of 5; the focused configuration suite truthfully characterizes the protected leaf failure while passing 17 of 17 assertions. Direct validation remains nonzero until the canonical conflict is separately approved and repaired. | Official archive hashes for supported Linux/Darwin architectures, corrupt/truncated/oversize negatives, authorization regression, protected-file approval, and exact-head CI. |
| O-53 | Order the prerequisite doctor so relationship errors are reported before repair attempts, Python is validated before Python-dependent probes, and peer names are canonicalized consistently. Reject an installed-but-unusable tool instead of reporting success from path presence. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Diagnosis grants no package, service, socket, or Tailscale mutation. | Focused fixtures pass 67 of 67. No host install or Tailscale action occurred. | Hermetic tool/version/peer fixtures, syntax and ShellCheck, independent current-byte review, and exact-head CI. |
| O-54 | Bind hello-world and teardown effects to exact Compose project, service, network, image, and immutable resource IDs. Late same-name resources are preserved and make the terminal receipt fail; evidence-capture children must reach bounded TERM-to-KILL extinction before their private evidence directory is removed. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Cleanup may remove only invocation-owned local resources; no name-only, fleet, remote, or production deletion is authorized. | Independent review returned `GO` for the repaired live bytes. Hello-world passes 34 of 34 and teardown passes 14 of 14; no live container run is claimed. | Late-name races, probe failures, TERM-resistant capture, failed-extinction receipt retention, ShellCheck, exact-head Linux CI, and live behavior only when separately authorized. |
| O-55 | Bind background-process cleanup, NATS storage, and durable receipts to immutable process and filesystem identities. Propagate cleanup failure through IPC exit, prevent PID reuse and path retargeting, keep mount boundaries intact, and correlate startup health with the exact owned NATS child. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Cleanup must never signal an unrelated process or traverse/delete/write outside invocation-owned storage. Platform-specific process, mount, and descriptor support must fail closed. | Multiple RED/GREEN batches are present; the latest independent process review remains `NO-GO` while fd-authoritative NATS runtime paths, receipt publication, process-handle races, and health correlation are repaired. No live NATS service result is claimed. | Mutable-variable, same-name, mount, PID-reuse, occupied-port, foreign-health, receipt-retarget, cleanup-failure, and exact-child fixtures; independent re-review and exact-head Linux CI. |
| O-56 | Harden AlexNet deploy, launch, wait, collect, teardown, and chaos evidence around descriptor-bound launcher hashes, immutable container IDs, bounded log reads, live-job signal ownership, exact result-tree cleanup, and truthful C4-C6 postconditions. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Remote hosts, Tailscale, Podman, deployment, teardown, and destructive chaos remain separately authorized effects. Local fixtures must not claim live-fleet proof. | The second repair batch passes 124 of 124 operations cases, 27 of 27 teardown cases, and 10 of 10 filesystem races. Its eight-path patch digest is `7f553b1789bd4955033e62ae806d0bb635701dbef5e96fa7663e74f2cf404e2d`; independent re-review is pending. | Same-name replacement, private CID receipt, launcher mutation/stale reuse, exact run-ID, stuck/oversize log, post-reap signal, partial-result, and C4 identity fixtures plus exact-head CI. |
| O-57 | Replace direct reusable-provider-key mounts with a per-invocation scoped credential broker, bound request/response sizes, exact upstream target and method, canary scanning, bounded connection admission, complete teardown, and immutable trusted-policy execution. Require terminal merged evidence from the configured Athena reviewer. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | The reusable provider key remains host-process-only. A privileged same-host or bridge observer can replay only the random short-lived invocation bearer before teardown; that residual is explicit. Protected paths, hooks, candidate content, and review comments remain untrusted. | Focused hook, authentication, placeholder, poison, and terminal-evidence suites pass after successive RED/GREEN repairs; final exact-byte review and Linux container CI remain pending. | Wrong-reviewer resume, base-helper substitution, container-removal failure, saturation/recovery, split-response canary, missing protected path, poison payload, timeout, and cancellation fixtures. |
| O-58 | Make report publication transactional across ordinary exceptions and catchable signals, reject unsafe destinations, retain or roll back the prior target, and impose one explicit incremental size ceiling on stdin, existing content, and built or appended output. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Publication cannot promise crash atomicity for `SIGKILL`, power loss, or an unrecoverable rollback-write failure; callers must not represent multiple sinks as one transaction. | Signal rollback is repaired and its focused suite passed 20 of 20 before the later size-bound finding. The size ceiling and boundary-plus-one no-mutation evidence remain in repair. | Short-write signal fixture, parent/name/hardlink/symlink/FIFO races, existing and source size boundaries, rollback evidence, independent review, and exact-head CI. |
| O-59 | Parse actual Compose YAML semantics for image and Grafana credential gates. Ignore comments and decoys, decode quoted and escaped keys, walk mapping/list/merge forms, and fail closed on unresolved or interpolated operational values. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Validation grants no credential generation, rotation, deployment, or image pull authority. | Image validation passes 9 of 9; Grafana validation passes 18 of 18 plus the real repository gate after escaped-key and interpolation REDs. Independent current-byte re-review and CI remain pending. | Malformed YAML, comment/quoted/escaped-key, merge/list, false-value, unresolved interpolation, marker-binding, and actual-repository fixtures. |
| O-60 | Bind Nomad validation to the lexical repository root and retain a no-follow descriptor chain through every configured ancestor and parser read. Reject off-root, root/ancestor/final symlink, parent swap, name replacement, or non-regular input. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Validation grants no authority to change canonical Nomad configuration or render into a system path. | Focused validator tests pass 5 of 5 after root-symlink and parent-swap REDs. Linux parser execution and final independent review remain pending. | Lexical-root, root-link, ancestor-link, parent-swap, final-link, off-root, file-swap, parser-failure, and exact-head CI evidence. |
| O-61 | Make pre-push/pre-commit execution preserve cancellation, extinguish process groups, and execute only exact verified tooling whose transitive execution tree cannot be rewritten by candidate hooks. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Hooks may not be bypassed, and candidate code must not gain write access to the trusted execution tree. Unsupported sandbox or descriptor controls fail closed. | SIGTERM, SIGHUP, and SIGINT spawn-window cases are repaired. Independent review remains `NO-GO` while the same-UID candidate-write path into private tool snapshots is closed. | In-hook tool-replacement effect sentinel, transitive `git` binding, process-group extinction, exact pre-commit version, supported-host sandbox evidence, and exact-head CI. |
| O-62 | Treat every `Superseded` ADR as immutable governance history sourced from trusted Git objects, not as a writable proposal merely because it is not `Accepted`. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Accepted and Superseded ADR bodies remain byte-unchanged; governance transitions require a new proposal and human decision. | Focused single- and multi-harness fixtures pass for Superseded ADR denial. Final exact-head protected-ADR comparison remains pending. | Trusted-base status parsing, candidate status/body substitution negatives, accepted/superseded hash manifest, and exact-head review. |
| O-63 | Mount required-but-absent protected paths as inert owner-private placeholders, keep the session home limited to its state child, and bound/fence issue, diff, review, log, and tool payloads so poison content cannot become trusted instructions or unbounded output. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | A placeholder confers no read or write authority over the protected host path. Candidate content remains data. | Focused absent-boundary and poison suites are green in both harnesses; container execution remains exact-head Linux CI evidence. | File/directory absence matrix, mount-mode inspection, payload delimiters and limits, hostile instruction fixtures, and exact-head container CI. |
| O-64 | Correct current-versus-proposed authority and historical evidence claims in the architecture, deployment, NATS-authentication, and Lemonade documentation. Unretained spike metrics are labeled unverified and carry no activation weight. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Proposed ADRs are not deployed architecture; accepted ADR bodies and raw evidence remain unchanged. | Independent documentation review returned `GO` after the evidence-language repair. Markdownlint and exact-head link checks remain pending. | ADR status/index comparison, accepted-body hash check, link/anchor validation, Markdownlint, and exact-head CI. |
| O-65 | Execute `envsubst`, `nomad`, and `hclfmt` for Nomad rendering from exact verified private bytes under bounded process-group supervision, capped diagnostics, timeout, full extinction, and post-child boundary revalidation. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | Rendering remains confined to one explicit approved empty owner-private output directory and grants no deployment authority. | TDD moved the renderer from four expected failures to 29 of 29 focused checks; exact current-byte independent review and Linux parser CI remain pending. | Executable/parent swap sentinels, TERM-resistant descendant, output flood, timeout, rollback, parser failure, and exact-head CI. |
| O-66 | Keep legacy durable-runtime state under a retained no-follow descriptor chain and open SQLite through the bound state-directory descriptor rather than a mutable pathname. Fail closed on platforms that cannot prove descriptor-relative SQLite access. | Odysseus / [PR #511](https://github.com/HomericIntelligence/Odysseus/pull/511) | No process-wide `chdir`, pathname fallback, redirected Git environment, or silent durability downgrade is allowed. The supported operational lane is the repository's Linux-64/container environment. | Darwin proves the unsupported-host negative and runs 91 tests with Linux runtime cases skipped; authoritative ancestor-swap closure requires exact-head Linux CI. | State-mkdir and connect ancestor replacements, no replacement writes, per-connection descriptor clone, SQLite lifecycle, unsupported-host negative, full Linux suite, and independent review. |

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
