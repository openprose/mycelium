# mycelium pi extension

Experimental Pi extension for making mycelium a first-class part of the agent loop.

## Why this exists

This package exists to make mycelium feel native inside Pi **without** pushing Pi-specific behavior back down into `mycelium.sh`.

The intended layering is:

- `mycelium.sh` = durable git-native primitives
- `scripts/context-workflow.sh` = recommended arrival/orientation workflow
- `integrations/pi/` = Pi-specific activation, tool wiring, and hidden agent-loop nudges

That keeps the core CLI thin while still making mycelium useful inside a real coding-agent session.

## Current status

This is an experimental but dogfooded MVP.

Today it provides:

- `/mycelium` control surface with `status`, `on`, `off`, `reset`, and `help`
- `mycelium_context` tool for broader arrival/orientation context
- `mycelium_note` tool for structured note writing from inside Pi
- read-time exact-note injection for fresh notes on the current file object
- edit/write-time hidden follow-up reminders to update mycelium notes before wrap-up
- hidden state that survives reloads and branch navigation
- jj workspace support via `GIT_DIR` + `GIT_WORK_TREE` wiring

## Agent loop contract

When the extension is active, the intended loop is:

1. **Turn it on explicitly** with `/mycelium on`
2. **Read files normally**
   - successful built-in `read` calls may append fresh exact mycelium notes for the current file object
3. **Pull broader context when needed**
   - use `mycelium_context` before deeper work in unfamiliar areas
4. **Edit or write files normally**
   - successful built-in `edit` and `write` calls may append hidden note-follow-up reminders
5. **Before wrap-up**, leave/update notes with `mycelium_note`
   - touched paths
   - relevant directories when useful
   - the change commit

This is the minimal read-notes / write-notes loop we want agents to internalize.

## What activation does — and does not do

Activation is intentionally lightweight.

What `/mycelium on` does:

- enables `mycelium_context`
- enables `mycelium_note`
- enables hidden read-time exact-note reminders
- enables hidden edit/write follow-up reminders
- enables the small active-session mycelium prompt reminder

What it does **not** do:

- dump project-wide constraints/warnings into the chat
- auto-run broad context collection for arbitrary paths
- inject large repo context before the agent has actually focused on a file/path

Broad arrival context stays **path-specific** and is accessed via `mycelium_context`.

## Underground behavior

This extension intentionally keeps reminders **underground by default**.

That means:

- read-time exact-note reminders are appended to raw `read` tool results for the agent/model
- edit/write follow-up reminders are appended to raw `edit`/`write` tool results for the agent/model
- these reminders are **not** normal user-facing UI banners or notifications by default

That matches the design theme of mycelium and git notes: agent-facing, structured, and mostly underground.

## Fresh-note read behavior

When active, successful built-in `read` calls can append fresh exact notes discovered through:

- `scripts/context-workflow.sh <path> <ref>`

Important behavior:

- rely on the existing workflow script instead of reimplementing note-resolution logic in TypeScript
- only surface exact notes on the current file object
- skip archived/composted notes
- if many exact notes exist, list them first and then include detailed blocks
- truncate the reminder reasonably
- dedupe repeats for the same note payload within the current branch/session history

## Post-edit note follow-up behavior

When active, successful built-in `edit` and `write` calls can append a hidden follow-up reminder like:

- you changed this path
- remember to update or leave mycelium notes for the touched path and for the change commit before wrap-up
- use `mycelium_note` when the target is ready

This reminder is deduped **per path** within the current branch/session history.

## Tools

### `mycelium_context`

Wraps the recommended arrival workflow:

1. `mycelium.sh find constraint`
2. `mycelium.sh find warning`
3. `scripts/context-workflow.sh <path> [ref] [--history]`

If `scripts/context-workflow.sh` is not present, the tool falls back to `mycelium.sh read <path>` and clearly says that the full workflow script is unavailable.

### `mycelium_note`

Writes a structured mycelium note with explicit fields for:

- target
- kind
- title
- body
- slot
- status
- force
- edges

## When to use extension tools vs the raw CLI

Prefer the extension tools while you are inside Pi:

- `read` + automatic reminder injection: best default for exact fresh notes on the current file object
- `mycelium_context`: best default for arrival/orientation context on a path
- `mycelium_note`: best default for writing structured notes from the agent loop after the edit/write follow-up reminder nudges you

Use raw `mycelium.sh` from bash when you need something the extension does not expose yet, or when you are debugging:

- graph/navigation commands like `follow`, `refs`, `list`, `dump`, `doctor`
- import/export/branch/slot workflows
- inspecting raw note output or checking whether read-time reminder injection is behaving correctly
- repo scripting outside Pi's normal tool loop

## jj workspace behavior

This package is designed to work in jj workspaces.

Important details:

- it wires `GIT_DIR` + `GIT_WORK_TREE` when calling mycelium commands
- it resolves the current `jj @` commit when it needs a concrete ref for workflow context
- it avoids assuming that plain git `HEAD` points at the active jj workspace commit

## Practical edge cases

### Brand-new uncommitted files

Mycelium notes are attached to git objects, not just filesystem paths.

That means a brand-new uncommitted file may not yet be a stable mycelium note target in a jj workspace. In that case:

- still allow the hidden post-edit follow-up reminder to nudge the agent
- leave a directory note or change-commit note first if needed
- add the file-specific note once the file exists in a concrete commit/blob

### Duplicate extension loading

During dogfooding, load exactly one copy of the extension.

Use either:

- a symlink/package install under `~/.pi/agent/extensions/`
- or `pi -e /absolute/path/to/integrations/pi/index.ts`

Do **not** do both at once.

## Usage

Preferred dogfood install:

```bash
ln -sfn /absolute/path/to/mycelium/integrations/pi ~/.pi/agent/extensions/mycelium-pi
pi
```

One-off alternative:

```bash
pi -e /absolute/path/to/mycelium/integrations/pi/index.ts
```

Then inside Pi:

```text
/mycelium status
/mycelium on
```

## Package workflow

```bash
cd integrations/pi
bun install
bun test
bun run typecheck
```

## Design decisions and current contract

- Keep Pi-specific behavior out of `mycelium.sh` core runtime.
  - The extension belongs in `integrations/pi/` as an integration layer, while `mycelium.sh` stays a git-native primitive layer.
- Keep the extension dormant by default.
  - Activation is explicit via `/mycelium on` so inactive sessions do not get prompt pollution.
- Keep activation lightweight.
  - Activation turns the loop on, but does not auto-dump broader repo context.
  - Broad arrival context stays path-specific and explicit through `mycelium_context`.
- Do not reinvent note-resolution logic in TypeScript.
  - Exact-note discovery should rely on `scripts/context-workflow.sh` and existing mycelium CLI behavior instead of reimplementing slot/ref/path logic in the extension.
- Read notes when reading files.
  - Built-in `read` is the main automatic arrival hook.
  - Fresh exact notes for the current file object are appended to the raw `read` tool result when active.
  - If multiple exact notes exist, list them first, then include detail blocks, and truncate reasonably.
- Nudge note writing after edits.
  - Built-in `edit` and `write` append hidden follow-up reminders so the agent remembers to update notes for touched paths and the change commit before wrap-up.
- Keep reminders underground by default.
  - Read-time and post-edit reminders are agent-facing additions to raw tool results, not normal user-facing UI banners.
  - If debugging needs improve later, add explicit debug surfaces rather than making reminders visible by default.
- Prefer extension tools inside Pi.
  - Use `mycelium_context` and `mycelium_note` as the default agent loop.
  - Use raw `mycelium.sh` from bash for unsupported commands or debugging raw note behavior.
- Avoid duplicate extension loading.
  - During dogfooding, use either the symlink/package install path or `pi -e`, but not both at once.
- Treat jj workspaces as a first-class environment.
  - The extension wires `GIT_DIR` + `GIT_WORK_TREE` for mycelium commands and resolves the current `jj @` commit for workflow context when needed.

## Notes

- This package is intentionally scoped as a thin MVP, not a full policy/enforcement layer.
- Heavy enforcement and broad context rewriting are intentionally deferred until after dogfooding.
