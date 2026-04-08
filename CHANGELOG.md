# Changelog

All notable changes to mycelium are documented here.

Mycelium is underground — built for agents, by agents. This changelog is
the human-readable surface of that work.

Format follows [Keep a Changelog](https://keepachangelog.com/).
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Claude Code plugin** under `integrations/claude-code/` — four shell hooks (`SessionStart`, `PostToolUse(Read)`, `PostToolUse(Edit|Write)`, `Stop`) plus an OpenProse marketplace manifest. Session start injects the skill and high-signal notes; per-file reads inject exact notes on the current blob across the default ref and all slots; the stop hook nudges the agent to leave notes on any changed files, including on fresh repos with zero notes so the first note can be written.
- **Non-text note handling** in the Claude Code plugin: notes are classified via `file --mime-type`; text notes over 4 KB are truncated with a retrieval command; non-text notes (images, binaries, HTML) emit a type/size descriptor so the agent can decide how to view them via `git notes show`.
- **`PLUGIN-SPEC.md`** — unified adapter contract documenting the four behaviors any agent-platform adapter should implement (skill injection, per-file reads, mutation tracking, end-of-session nudge) and how Pi's dormant-by-default vs Claude Code's auto-activate models differ.
- **Plugin spec compliance test suite** at `test/test-plugin-spec.sh` — 40 assertions covering Claude Code hooks functionally and the Pi extension structurally, including hostile-`SKILL.md` rejection and the fresh-repo bootstrap path.
- **Pi extension skill injection on activation**: when `/mycelium on` transitions from off to on, the extension injects `SKILL.md` into the system prompt on the next agent turn; subsequent turns only get the short reminder, and `/mycelium off` resets the cycle.
- Pre-commit hook now runs `test/test-plugin-spec.sh` when `integrations/`, `PLUGIN-SPEC.md`, or the suite itself is staged, and runs `bun run typecheck && bun test` in `integrations/pi/` when those files are staged (gracefully skipped if `bun` is not installed).
- Experimental Pi extension MVP under `integrations/pi/` for the Pi coding agent, with opt-in activation plus built-in `mycelium_context` and `mycelium_note` tools.
- When the Pi extension is active, successful built-in `read` calls can surface fresh exact mycelium notes for the current file object, list multiple exact notes first, and dedupe repeats for the same note payload.
- When the Pi extension is active, successful built-in `edit` and `write` calls can add hidden note follow-up reminders so agents remember to leave or update mycelium notes after changing files.

### Fixed
- **`doctor` SIGPIPE on large notes**: `cmd_doctor` previously piped each note's content through `echo "$content" | awk '...exit'`. Under `set -o pipefail`, `awk`'s early exit on large notes produced SIGPIPE and killed the whole command. Replaced with herestring (`awk ... <<< "$content"`). Fixed the same pattern in `_find_by_change_id`.
- **Claude Code plugin inert on fresh repos**: the hooks previously had `[ note_count -eq 0 ] && exit 0` guards, so a fresh git repo with zero mycelium notes never saw the skill, never tracked mutations, and never got the stop-hook nudge. The first note could never be written. All four hooks now fire in any git repo regardless of note count.

### Security
- **Path traversal via unvalidated session ID**: the post-write and stop hooks interpolated `session_id` directly into `/tmp/mycelium-cc-<id>.changed` without validation. A crafted session id could redirect an append-write or enable arbitrary file unlink at stop time. Now gated behind `^[A-Za-z0-9_-]{1,64}$`.
- **Prompt injection via arbitrary repo SKILL.md**: `mycelium.sh prime` fell back to `$repo_root/SKILL.md` when the script directory didn't have one. Any repo with an unrelated top-level `SKILL.md` could inject content into agent context via tools that consumed prime output. `prime` now accepts `$repo_root/SKILL.md` only when `$repo_root/mycelium.sh` also exists (identifying the mycelium source repo specifically); otherwise it falls through to the inline minimal skill. The Pi extension's `readSkillMd()` resolves strictly via `import.meta.url`, walking up from the extension's own install path rather than trusting `workspaceRoot`.

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
