# Mycelium Integrations

Agent platform adapters that bring mycelium notes into the agent loop.

## What adapters do

Every adapter implements four behaviors:

1. **Session start** — Inject the mycelium skill (SKILL.md), constraint
   notes, warning notes, and graph state so the agent knows the protocol
   and project rules from turn one.

2. **Per-file notes on read** — When the agent reads a file, surface all
   mycelium notes on that file's current blob (default ref + all slots).
   If no notes exist, stay silent.

3. **Mutation tracking** — Record which files the agent edits. No output.

4. **End-of-session nudge** — When the agent finishes, list changed files
   and suggest leaving notes for future agents.

Notes are injected underground — visible to the agent/LLM but hidden from
the primary user interface.

## Available adapters

### Claude Code

A Claude Code plugin using shell hooks. In Claude Code, run `/plugins`,
select "Add Marketplace", and enter `openprose/mycelium`. Then enable
`mycelium@openprose-mycelium`.

Requires `jq` and `mycelium.sh` in PATH or at `~/.local/bin/mycelium.sh`.

See [claude-code/](claude-code/) for the plugin structure.

### Pi

A TypeScript extension for the Pi coding agent.

```bash
# Symlink the pi integration directory — this is a full bun package
ln -sfn /path/to/mycelium/integrations/pi \
  ~/.pi/agent/extensions/mycelium-pi
```

Requires `mycelium.sh` at `~/.agents/skills/mycelium/mycelium.sh` or
`~/.local/bin/mycelium.sh`.

See [pi/index.ts](pi/index.ts) for the extension source.

## What adapters do NOT do

- **Write notes.** The adapter nudges; the agent decides. Notes are
  written via `mycelium.sh note` in the shell.
- **Run context-workflow.sh.** The full arrival workflow (file + parent
  dirs + commit + imports) is available to agents but not automatic.
  Adapters only inject the exact-blob notes on Read.
- **Manage imports/exports.** Multi-repo features are not adapter concerns.
- **Add core subcommands.** Adapters compose existing mycelium primitives.
  No new subcommands are added to mycelium.sh for adapter use.

## Building a new adapter

Any platform that provides session-start, post-read, post-write, and
session-end events can implement these behaviors. The adapter is a thin
translation layer between platform events and mycelium primitives:

- `mycelium.sh find constraint` / `mycelium.sh find warning` for session start
- `git rev-parse HEAD:<path>` + `git notes --ref=mycelium show <oid>` for per-file reads
- `git for-each-ref refs/notes/mycelium--slot--*` for slot enumeration
- `mycelium.sh doctor` for graph state

See [PLUGIN-SPEC.md](../PLUGIN-SPEC.md) for the full specification.

## Testing

```bash
# Spec compliance tests for both adapters
bash test/test-plugin-spec.sh
```
