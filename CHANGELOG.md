# Changelog

All notable changes to Odysseus are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

---

## [0.4.0] - 2026-03-29

### Changed
- Rewrote `docs/architecture.md` to reflect post-ADR-006 state: ai-maestro removed as active
  component, ProjectAgamemnon + ProjectNestor + ProjectCharybdis documented with accurate roles,
  Keystone transport layer detailed, NATS subject schema table added.
- Updated `CLAUDE.md` structure tree: added ADR-005 and ADR-006, refreshed submodule descriptions.
- Updated runbooks to replace all ai-maestro references with Agamemnon equivalents.

### Added
- ADR-006: Decouple from ai-maestro (full migration rationale and decisions).
- Submodules: `control/ProjectAgamemnon`, `control/ProjectNestor`, `testing/ProjectCharybdis`.
- Architectural analysis reports: `docs/odysseus-ruflo-analysis.md`, `docs/odysseus-ai-maestro-analysis.md`.

### Removed
- `infrastructure/ai-maestro` submodule removed per ADR-006.

---

## [0.3.0] - 2026-03-27

### Added
- `.claude/settings.json`: enable `hephaestus@ProjectHephaestus` plugin for Claude Code sessions.

---

## [0.2.0] - 2026-03-23

### Added
- `.github/workflows/ci.yml`: CI workflow that validates YAML/JSON in `configs/` on every push and PR.

---

## [0.1.1] - 2026-03-16

### Fixed
- Corrected ProjectKeystone and ProjectHephaestus documentation.
- Documented NATS subject schema.
- Added justfile recipes for infrastructure and provisioning services.

---

## [0.1.0] - 2026-03-15

### Added
- Initial Odysseus meta-repo scaffold.
- Architecture Decision Records: ADR-001 through ADR-005.
- Runbooks: add-new-host, add-new-agent-type, disaster-recovery.
- Nomad configs: `configs/nomad/client.hcl`, `configs/nomad/server.hcl`.
- NATS configs: `configs/nats/server.conf`, `configs/nats/leaf.conf`.
- `justfile` with bootstrap, status, apply-all, and service-start recipes.
- `pixi.toml` with `just` dependency.
- Local dev symlinks for all submodule paths (dev convenience, not portable).
