# mycelium pi extension

Experimental Pi extension for making mycelium a first-class part of the agent loop.

## MVP goals

- stay dormant by default
- avoid prompt pollution when inactive
- add a small `/mycelium` control surface
- expose deterministic tools for arrival context and note writing
- work in jj workspaces by wiring `GIT_DIR` + `GIT_WORK_TREE` for mycelium commands

## Current behavior

- Registers `/mycelium` with `status`, `on`, `off`, `reset`, and `help`.
- Keeps `mycelium_context` and `mycelium_note` out of the active tool set until `/mycelium on`.
- Tracks successful `read`, `edit`, and `write` paths in hidden session state so reminders survive reloads and branch navigation.
- When active, successful built-in `read` results can append fresh exact mycelium file notes from `scripts/context-workflow.sh`.
- Multiple exact notes are listed first, then detailed blocks follow, and repeat reads of the same note payload are deduped.
- When active, appends a short system-prompt reminder to use mycelium context before unfamiliar edits and to leave notes before wrap-up.

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

## Usage

During local development, load exactly one copy of the extension.

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

## When to use extension tools vs the raw CLI

Prefer the extension tools while you are inside Pi:

- `read` + automatic reminder injection: best default for exact fresh notes on the current file object
- `mycelium_context`: best default for arrival/orientation context on a path
- `mycelium_note`: best default for writing structured notes from the agent loop

Use raw `mycelium.sh` from bash when you need something the extension does not expose yet, or when you are debugging:

- graph/navigation commands like `follow`, `refs`, `list`, `dump`, `doctor`
- import/export/branch/slot workflows
- inspecting raw note output or checking whether read-time reminder injection is behaving correctly
- repo scripting outside Pi's normal tool loop

## Notes

- This package is intentionally scoped as a thin MVP, not a full policy/enforcement layer.
- Heavy enforcement and broad context rewriting are intentionally deferred until after dogfooding.
- Avoid duplicate extension loading from both `-e` and `~/.pi/agent/extensions` at the same time.
