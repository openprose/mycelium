# Changelog

All notable changes to mycelium are documented here.

Mycelium is underground — built for agents, by agents. This changelog is
the human-readable surface of that work.

Format follows [Keep a Changelog](https://keepachangelog.com/).
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Experimental Pi extension MVP under `integrations/pi/` with `/mycelium`, `mycelium_context`, `mycelium_note`, jj-workspace git wiring, and hidden touched-path state.

## [0.3.0] — 2026-04-01

### Added
- **Batch export**: `export --all [--kind <k>] --audience <a>` exports all notes
  (or filtered by kind) in one command. Respects public export policy.
- **`list-imports`**: shows imported repos with name, note count, fetch date,
  and source remote.
- **Foreign object labels**: imported objects that can't be resolved locally
  display `ext:` instead of `??:` for cleaner output alignment.
- `CHANGELOG.md` — human-readable release history.
- Release policy documented for stable vs prerelease install channels.
- Phase 2 test suite (24 assertions).

### Changed
- **Thin core**: `context` and `compost` moved from `mycelium.sh` to
  `scripts/context-workflow.sh` and `scripts/compost-workflow.sh`.
  The CLI no longer ships these as built-in commands — they live in
  the agent skill/workflow layer.
- `supersedes` header dropped. Auto-supersede on overwrite still
  preserves the old blob OID in an edge.
- `export --all` rejects being combined with a positional target.
- Internal code deduplication in export path.

### Removed
- `context` and `compost` CLI shims (moved to workflow scripts).

## [0.2.0] — 2026-03-29

### Added
- **Multi-repo export/import** (Phase 0 + Phase 1):
  - `repo-id [init]` — durable repository identity.
  - `zone [init [level]]` — confidentiality level (default 80).
  - `export <target> --audience <internal|public>` — publish notes to
    export refs with policy gating.
  - `import <remote> [--as <name>] [--refresh]` — fetch foreign export
    ref into read-only local import ref.
  - `sync-init --export-only` — configure refspecs for export refs only.
- Export policy file (`.mycelium/export-policy`) with `allowed_kinds`
  and `deny_patterns`.
- `hooks/reference-transaction` — gates writes to public export refs
  against the export policy.
- `context`, `find`, `kinds`, `doctor` aggregate across imports with
  `[import:name]` labels.
- Read-only enforcement on import and export refs.
- **Overwrite guard**: `note` requires `-f`/`--force` to overwrite
  existing notes.
- **Versioning**: `mycelium.sh --version` derives version from git tags
  at runtime. Installer stamps non-git copies.
- CI workflow (`.github/workflows/ci.yml`) runs all test suites.
- Phase 0 test suite (61 assertions).
- Phase 1 test suite (39 assertions).

## [0.1.0] — 2026-03-26

### Added
- Core note graph: `note`, `read`, `find`, `list`, `kinds`, `edges`,
  `follow`, `doctor`, `prime`, `dump`, `log`.
- Slot system: `--slot <name>` for multi-ref notes on the same object.
- Branch system: `branch use/merge` for parallel notes refs.
- `migrate` command for reattaching notes after jj rewrites.
- `activate` command for git log integration.
- Compost (decomposition) and context (path-based aggregation) as
  workflow scripts.
- Installer (`install.sh`) with curl-to-bash bootstrap.
- Pre-commit and pre-push hooks.
- Core test suite (265+ assertions).
- SKILL.md — agent convention for the mycelium layer.

[Unreleased]: https://github.com/openprose/mycelium/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/openprose/mycelium/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/openprose/mycelium/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/openprose/mycelium/releases/tag/v0.1.0
