---
name: mycelium
description: >
  Hidden layer of structured git notes for agent collaboration. When working in any
  git repo, check for mycelium notes on objects you touch (files, directories, commits)
  before acting, and leave notes after meaningful work. Uses git notes directly —
  helper script available but not required.
---

# Mycelium

Structured notes attached to git objects via `refs/notes/mycelium`.

**Before working on a file, check for its note. After meaningful work, leave a note.**

That's the whole contract. How you work, what you build, how you talk to your user —
that's your business. Mycelium just asks you to read the breadcrumbs and leave new ones.

## On arrival

Start every session with:

```bash
mycelium.sh find constraint            # project principles & rules
mycelium.sh find warning               # known fragile things
mycelium.sh context <file-you-will-touch>  # everything known about it
```

Before leaving:

```bash
mycelium.sh note HEAD -k context -m "What I did and why."
mycelium.sh note <changed-file> -k <kind> -m "What future agents should know."
```

If you made a decision, use `kind decision` and add a `tested-by` edge to the test
that validates it. If you found something fragile, use `kind warning`.

## Patterns

Three patterns cover most usage. Learn these before the commands.

### Pattern 1: One ref accumulates many notes

A file gets noted by different agents at different times. Each edit creates a new
blob, but old notes persist and surface as `[stale]`. The file's full history of
understanding is always available.

```bash
# Agent A summarizes the file
mycelium.sh note src/auth.ts -k summary -m "Handles OAuth2 refresh flow."

# Agent B adds a warning (days later, file has changed)
mycelium.sh note src/auth.ts -k warning -m "Token refresh has a race condition."

# Agent C arrives and sees everything — current + stale notes + parent dir + commit
mycelium.sh context src/auth.ts

# Or see every note that references this file (inbound edges)
mycelium.sh refs src/auth.ts
```

**When to use:** Always. This happens naturally. Every note you write on a file
contributes to this pattern. Use `context` on arrival, `refs` when you need the
full picture.

### Pattern 2: One note connects many refs

A single note can link to multiple objects via edges. This is how you express
relationships — a decision that affects two files, a constraint that depends on
a spec, a plan that ties together several changes.

```bash
# A decision note on SKILL.md that also depends on the spec
mycelium.sh note SKILL.md -k decision -t "Packaged as an agent skill" \
  -e "depends-on blob:$(git rev-parse HEAD:mycelium.md)" \
  -m "The skill teaches agents the convention on-demand."

# Read the note and see where all edges lead
mycelium.sh follow SKILL.md
# Output:
#   --- edges ---
#     applies-to  → blob:2e4a79... [decision] Packaged as an agent skill
#     targets-path → path:SKILL.md (no note)
#     depends-on  → blob:b34ab1... [summary] The minimal spec
```

**When to use:** Whenever a note's meaning involves more than one object. Decisions
that affect multiple files. Constraints that depend on specs. Warnings that
reference the commit that introduced the problem.

### Pattern 3: Planning graph

Use `depends-on` edges to structure planned work. A planning note on a commit
points to file-level notes describing what each file needs. Arriving agents
follow the graph to understand the full scope.

```bash
# Note on each file describing what needs to change
mycelium.sh note src/auth.ts -k context -t "Planned: fix race condition" \
  -m "Need mutex around token refresh. See warning note."

mycelium.sh note src/http.ts -k context -t "Planned: retry after refresh" \
  -m "HTTP client should retry once after auth refresh."

# Tie them together with a planning note on HEAD
mycelium.sh note HEAD -k context -t "Plan: auth hardening" \
  -e "depends-on blob:$(git rev-parse HEAD:src/auth.ts)" \
  -e "depends-on blob:$(git rev-parse HEAD:src/http.ts)" \
  -m "Two files need coordinated changes."

# Arriving agent follows the plan
mycelium.sh follow HEAD
# Output:
#   --- edges ---
#     explains   → commit:abc123... (the commit)
#     depends-on → blob:def456... [context] Planned: fix race condition
#     depends-on → blob:789abc... [context] Planned: retry after refresh
```

**When to use:** Before starting multi-file work. Before handing off to another
agent. The graph is the work queue — `follow` shows the plan, `refs` on any
file shows what plans involve it.

## Check for notes

```bash
# On a file you're about to work on
mycelium.sh context path/to/file.ts    # file + stale + parent dirs + commit

# What points at this file?
mycelium.sh refs path/to/file.ts       # all notes with edges to this object

# Read a note and resolve its edges
mycelium.sh follow HEAD                # note + where each edge leads

# Quick lookups
mycelium.sh read path/to/file.ts       # just the note on this object
mycelium.sh find decision              # all decisions
mycelium.sh find constraint            # all constraints
git log --notes=mycelium --oneline -20  # recent commits with notes
```

Or with raw git (no helper needed):

```bash
git notes --ref=mycelium show $(git rev-parse HEAD:path/to/file.ts) 2>/dev/null
git notes --ref=mycelium show HEAD 2>/dev/null
```

## Leave notes

```bash
mycelium.sh note -k context -m "Why I did this."                     # HEAD
mycelium.sh note path/to/file.ts -k summary -m "What this does."     # file
mycelium.sh note src/auth/ -k constraint -m "Must be retryable."     # directory
mycelium.sh note . -k value -m "Project-level principle."            # project
mycelium.sh note -k decision -t "Use YAML" -m "Needs comments."     # decision
```

### Target stability

Every target has different stability. The tool tells you on write:

| Target | Stable? | Use when |
|--------|---------|----------|
| `path/to/file` | ✓ findable by path even if file changes | Note is about the file |
| `$(git rev-parse HEAD:file)` | pinned to this exact blob OID | Note is about this specific version |
| `.` | ✓ project-level, always findable | Note applies to the whole repo |
| `HEAD` | pinned to commit OID (jj: survives via change_id) | Note is about this change |
| `src/dir/` | ✓ findable by path | Note is about the module |

**Default: use paths.** Most notes are about files, not specific versions. The path
edge keeps them findable. Use raw OIDs only when you mean "this exact content."

Extra edges beyond the auto-generated ones:

```bash
mycelium.sh note src/auth.ts -k warning \
  -e "depends-on blob:$(git rev-parse HEAD:src/http.ts)" \
  -m "Auth and HTTP client share retry state."
```

Or with raw git (no helper needed):

```bash
BLOB=$(git rev-parse HEAD:path/to/file.ts)
git notes --ref=mycelium add -m 'kind summary
edge applies-to blob:'"$BLOB"'
edge targets-path path:path/to/file.ts

What this file does and anything worth knowing.' "$BLOB"
```

## Note format

```
kind decision
title Short label
edge explains commit:abc123...
edge targets-path path:src/auth/retry.ts

Free-form body. Markdown encouraged.
```

**Headers**: `kind` (required), `edge`, `title`, `status`, `supersedes`.
**Kinds**: `decision` · `context` · `summary` · `warning` · `constraint` · `observation` · `value` · `todo` — or invent your own.
**Edge types**: `explains` · `applies-to` · `depends-on` · `warns-about` · `targets-path` — or invent your own.
**Targets**: `commit:<oid>` · `blob:<oid>` · `tree:<oid>` · `path:<filepath>` · `note:<oid>`

## Supersession

Notes are never silently destroyed. When you write a note on an object that already
has one, the old note's blob OID is preserved in a `supersedes` header. The tool
does this automatically. The chain is the history of how understanding evolved —
downstream tools walk it to extract what changed.

## Setup (once per clone)

```bash
mycelium.sh activate        # notes visible in git log
mycelium.sh sync-init       # notes travel with fetch/push
```

## Composting

Notes go stale when the file they describe changes. Stale notes aren't wrong —
they're about an older version. Composting triages them.

**After meaningful work, compost the files you touched:**

```bash
# 1. See what's stale
mycelium.sh compost src/auth.ts --dry-run
#   [value] Pave the desire path — src/auth.ts (0b2e12db5f02)
#   [summary] Auth module overview — src/auth.ts (921ef648f987)

# 2. Read the ones you're unsure about
mycelium.sh read 921ef648f987

# 3. Act on individuals by OID
mycelium.sh compost 921ef648f987 --compost   # insight absorbed, compost it
mycelium.sh compost 0b2e12db5f02 --renew     # still true, re-attach to current

# Or batch: act on all stale notes for a path
mycelium.sh compost src/auth.ts --compost    # compost all stale on this path
mycelium.sh compost src/auth.ts --renew      # renew all stale on this path

# Counts only (for hooks)
mycelium.sh compost --report
```

Composted notes aren't deleted. They're still in `read`, `dump`, and
`context --all`. They just stop cluttering the topsoil.

`context` shows stale notes as one-line summaries — run `read <oid>` for
the full body. Composted notes are hidden unless you pass `--all`.

The interactive mode (`mycelium.sh compost src/auth.ts` with no action flag)
prompts per-note for humans. Agents should use `--dry-run` + `--compost`/`--renew`.

## Slots

Multiple tools or agents can write notes on the same object without obliteration.
Each slot is a named lane backed by its own notes ref.

```bash
# Write to named slots
mycelium.sh note src/auth.ts --slot skeleton -k observation -m "Structure."
mycelium.sh note src/auth.ts --slot enricher -k summary -m "Context."

# Read from a specific slot
mycelium.sh read src/auth.ts --slot skeleton

# Aggregation commands scan all slots by default
mycelium.sh context src/auth.ts    # shows notes from every slot, labeled
mycelium.sh find decision          # finds across all slots
mycelium.sh doctor                 # counts all slots

# Compost per-slot
mycelium.sh compost src/auth.ts --slot skeleton --compost
mycelium.sh compost src/auth.ts --compost    # batch: all slots
```

**Rules:**
- `read`/`follow` use the default slot unless `--slot` given
- `context`/`find`/`kinds`/`doctor`/`prime` aggregate all slots
- Supersedes is intra-slot only — writing to skeleton never touches enricher
- Bare OID compost errors if multiple slots match — use `--slot` to disambiguate
- Reserved names: `main`, `default`

## All commands

```
mycelium.sh note [target] -k <kind> -m <body>   Write (default: HEAD)
mycelium.sh read [target] [--slot <name>]        Read (default: HEAD)
mycelium.sh follow [target] [--slot <name>]      Read + resolve all edges
mycelium.sh refs [target]                        All notes pointing at target
mycelium.sh context <path> [--all]               All notes for a path
mycelium.sh find <kind>                          Find by kind
mycelium.sh kinds                                List all kinds in use
mycelium.sh compost [path|oid] [--compost|--renew|--dry-run|--report] [--slot]
mycelium.sh edges [type]                         List edges
mycelium.sh list                                 All annotated objects
mycelium.sh log [n]                              Recent commits with notes
mycelium.sh dump                                 Everything, greppable
mycelium.sh doctor                               Graph health (facts only)
mycelium.sh prime                                Skill + live repo context
mycelium.sh branch [use|merge] [name]            Branch-scoped notes
mycelium.sh activate                             Show in git log
mycelium.sh sync-init [remote]                   Configure fetch/push
```

## jj+git colocated repos

If `.jj/` is detected, mycelium adapts automatically — no flags needed. Commit notes get a `targets-change` edge (stable across jj rewrites). `read` falls back to change_id lookup when the commit OID changes. Prefer notes on files over commits — blob OIDs survive rewrites, commit OIDs don't. Run `mycelium.sh help` for jj-specific guidance.
