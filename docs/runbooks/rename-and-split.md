# Historical Record: Repository Rename and Hephaestus/Athena Split

This migration is complete and this file is not an executable runbook.
[Accepted ADR-015](../adr/015-drop-project-prefix.md) records the repository
rename decision, and [Accepted ADR-016](../adr/016-split-hephaestus.md) records
the Hephaestus/Athena split.

The completed migration renamed the former `Project<X>` repositories, retained
Hephaestus as the library/runtime owner, created Athena as the public plugin and
skill owner, and updated Odysseus integration references through reviewed
changes. Git history and the merged migration pull requests preserve the
original commands and receipts; they must not be replayed against the current
repositories.

Current facts belong to live sources:

- `.gitmodules` owns component paths, names, and remote URLs.
- Gitlink entries in the Odysseus commit tree own component SHAs; pins are not
  stored in `.gitmodules`.
- `scripts/install/60-claude-tooling.sh` owns the current local plugin setup.
- Athena's repository contract and package metadata own the public
  `athena@Athena` plugin surface.
- Hephaestus's repository contract owns its current runtime and automation
  surfaces.

Do not use this historical record to rename a repository, move a gitlink,
rewrite a remote, generate plugin content, reset a branch, or roll back an
integration. A future rename or split requires a new accepted decision,
fresh immutable repository inventories, explicit remote-write and integration
approval, isolated component pull requests, and exact-head review and CI/CD.

For ordinary current work, follow the applicable repository's `AGENTS.md`
contract. Load its onboarding, README, architecture, or component documents only
when the task needs that context.
