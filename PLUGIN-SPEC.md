# Mycelium Plugin Spec — Unified Adapter Contract

How agent platforms (Pi, Claude Code, others) should integrate mycelium.
This spec defines **what** an adapter must do, not how. Each platform
implements these behaviors using its own extension surface.

## Architectural constraints

These are settled decisions in the mycelium project. Adapters must
respect them.

1. **Thin core.** `mycelium.sh` is the substrate. Adapters compose
   existing primitives (`read`, `find`, `doctor`, `dump`) and
   repo-shipped workflow scripts. No new core subcommands for
   adapter concerns.

2. **Workflow layer.** Context arrival and compost lifecycle belong
   in SKILL.md and `scripts/`. They are not core CLI semantics.
   Adapters teach agents the skill, then agents use the primitives.

3. **Underground by default.** Mycelium notes are agent-facing. Adapter
   injections should be hidden from the primary user UI where the
   platform supports it (`display: false` in Pi, `additionalContext`
   in Claude Code). Debugging surfaces are fine; default user-visible
   banners are not.

4. **Tool vs project.** The adapter ships no project-specific
   assumptions. A repo with 3 notes and no constraints is as valid
   as one with 137.

5. **Doctor reports facts.** Never interpret doctor output as
   prescriptive. Don't tell the agent "you should fix N stale notes."
   Just show the state.

## Behaviors

### 1. Session start: inject skill + high-signal notes

**When:** New session begins (not resume/compact).

**What to inject:**

| Content | Source | Required |
|---------|--------|----------|
| SKILL.md | Repo root, or global install location | Yes |
| Constraint notes | `mycelium.sh find constraint` | Yes, if any exist |
| Warning notes | `mycelium.sh find warning` | Yes, if any exist |
| Note count | `git notes --ref=mycelium list \| wc -l` | Yes |

**What NOT to inject at session start:**

- Full `mycelium.sh dump` (too noisy, wastes context on notes the
  agent may never need)
- All decision notes (let the agent discover these via `find` if needed)
- Recent commit log with notes (the agent can run `mycelium.sh log`
  if it wants this)

**Visibility:** Hidden from user UI. Agent/LLM sees it.

**Guard:** Only fire in git repos where `refs/notes/mycelium` has at
least one note. Exit silently otherwise.

### 2. Per-file note injection on read

**When:** Agent reads a file (Read tool, or platform equivalent).

**What to inject:** All mycelium notes attached to the file's current
blob OID. A single blob can have multiple notes across the default
ref and slot refs — inject all of them.

**How:**

```bash
# Default ref
mycelium.sh read <relative-path>

# All slots (if any exist)
for slot in $(mycelium.sh ... slot enumeration ...); do
  mycelium.sh read <relative-path> --slot "$slot"
done
```

Or, if the adapter prefers raw git to avoid multiple subprocess calls:

```bash
OID=$(git rev-parse HEAD:<relative-path>)
# Check default ref
git notes --ref=mycelium show "$OID"
# Check each slot ref
for ref in $(git for-each-ref --format='%(refname:short)' refs/notes/mycelium--slot--*); do
  git notes --ref="$ref" show "$OID"
done
```

**Content handling:**

Git notes can be any content type — text, images, binaries, HTML.
Adapters must classify each note blob before injecting:

| Content type | Action |
|---|---|
| Text, ≤ 4KB | Inject as-is |
| Text, > 4KB | Truncate to 4KB, append size and retrieval command |
| Binary (null bytes detected) | Do not inject content. Emit a one-line descriptor: type, size, and `git notes show` command so the agent can decide how to view it |

Detection: pipe the blob through `file --mime-type` to classify.
Text notes have `text/*` MIME types; everything else is non-text.

```bash
mime=$(git cat-file -p <blob> | file -b --mime-type -)
# text/plain, text/html → text (inject)
# image/png, application/pdf → non-text (describe)
```

**What NOT to inject:**

- Parent directory notes (the agent can run `context-workflow.sh` if
  it wants the full inheritance chain)
- Notes on older blob versions (stale notes on previous file content)
- Project-level root tree notes (already covered by session start
  constraints/warnings)

**Visibility:** Hidden from user UI. Agent/LLM sees it alongside the
file content.

**Guard:** Only fire in repos with mycelium notes. If the file has no
notes on its current blob, inject nothing (not even a "no note found"
message).

**Performance note:** This fires on every file read. Keep it fast.
Prefer raw git over `mycelium.sh read` if subprocess cost is a concern,
since `git rev-parse` + `git notes show` is cheaper than loading and
parsing the full bash script.

### 3. Track file mutations

**When:** Agent writes or edits a file (Write/Edit tool, or platform
equivalent).

**What to do:** Record the file path. No output to LLM. No user-visible
side effect.

**Implementation is platform-specific:**

- In-process: set/list in memory (Pi approach)
- Out-of-process: append to a temp file keyed by session ID
  (Claude Code approach)

### 4. End-of-session nudge

**When:** Agent finishes responding / session ends.

**Condition:** Files were mutated AND the repo uses mycelium notes.

**What to inject:** A message listing the changed files and suggesting
the agent leave notes. Include the file list and a usage example:

```
📡 N file(s) changed — consider leaving mycelium notes:
  - path/to/file1
  - path/to/file2

Use: mycelium.sh note <file> -k <kind> -m "<what future agents should know>"
```

**Strength:** Platform-specific. Options from softest to hardest:

| Level | Mechanism | Platform |
|-------|-----------|----------|
| Passive | Status bar text | Pi (`ctx.ui.setStatus`) |
| Moderate | Context injection | Any (`additionalContext`) |
| Blocking | Stop-gate | Claude Code (`decision: block`) |

The spec recommends **blocking** as the default. The agent should see
the changed files and consciously decide whether to leave notes. A
passive status bar is easy to ignore.

**Guard:** Must check `stop_hook_active` or equivalent to prevent
infinite loops. The nudge fires once; if the agent stops again, let
it go.

**Visibility:** Underground-compatible. The nudge is agent-facing.
If the platform can hide it from the user UI, do so.

### 5. Behaviors NOT in this spec

These are explicitly out of scope for the adapter:

- **Writing notes.** The adapter nudges; the agent decides. The agent
  calls `mycelium.sh note` via bash/shell, not through the adapter.
- **Compost/stale lifecycle.** Opt-in workflow. Taught by SKILL.md,
  executed by agent using `scripts/compost-workflow.sh`.
- **Context-workflow.sh.** The full arrival workflow (file + parents +
  commit + imports). The agent can run this manually. The adapter only
  does the exact-blob note injection on Read.
- **Import/export.** Multi-repo features. Not adapter concerns.
- **Branch-scoped notes.** The adapter uses whatever ref is active
  (`$MYCELIUM_REF` or `.git/mycelium-branch`). No special handling.

## Platform implementation notes

### Pi

Pi's `ExtensionAPI` provides `before_agent_start`, `tool_result`, and
`agent_end` events. The extension is in-process TypeScript.

Current implementation gap: `before_agent_start` runs `mycelium.sh dump`
(all notes) instead of the targeted injection this spec requires.
It also does not inject SKILL.md.

Does not implement per-file note injection on Read.

### Claude Code

Claude Code provides shell hooks: `SessionStart`, `PostToolUse`, `Stop`.
Each hook is an out-of-process bash script reading JSON from stdin.

Current implementation matches this spec for all four behaviors.

Performance concern: each hook spawns subprocesses (`jq`, `git`,
`mycelium.sh`). The per-file Read hook should minimize subprocess
calls — consider caching the "does this repo use mycelium" check
per session rather than re-running `git notes list | wc -l` on
every Read.

### Future platforms

Any platform that provides:
1. A session-start event
2. A post-read event (or pre-read)
3. A post-write event
4. A session-end or stop event

...can implement this spec. The adapter is a thin translation layer
between platform events and mycelium primitives.

## Mycelium.sh version requirement

This spec assumes mycelium.sh v0.3.0+, which includes `find`, `doctor`,
`read` with slot support, and `targets-path` edges on file notes.

## Testing

For any adapter:

1. Open a session in a repo with mycelium notes on a file.
2. Verify session start injects SKILL.md + constraints + warnings + doctor.
3. Read the annotated file. Verify the note appears in agent context.
4. Read an unannotated file. Verify nothing is injected.
5. Edit a file, then end the session. Verify the nudge lists the file.
6. Open a session in a repo without mycelium. Verify all hooks are silent.
