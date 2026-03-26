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
mycelium.sh note -k decision -t "Use YAML" -m "Needs comments."     # decision
```

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
**Kinds**: `decision` · `context` · `summary` · `warning` · `constraint` · `observation` — or invent your own.
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

## All commands

```
mycelium.sh note [target] -k <kind> -m <body>   Write (default: HEAD)
mycelium.sh read [target]                        Read (default: HEAD)
mycelium.sh follow [target]                      Read + resolve all edges
mycelium.sh refs [target]                        All notes pointing at target
mycelium.sh context <path>                       All notes for a path
mycelium.sh find <kind>                          Find by kind
mycelium.sh kinds                                List all kinds in use
mycelium.sh edges [type]                         List edges
mycelium.sh list                                 All annotated objects
mycelium.sh log [n]                              Recent commits with notes
mycelium.sh dump                                 Everything, greppable
mycelium.sh doctor                               Graph health (facts only)
mycelium.sh branch [use|merge] [name]            Branch-scoped notes
mycelium.sh activate                             Show in git log
mycelium.sh sync-init [remote]                   Configure fetch/push
```

## jj+git colocated repos

If `.jj/` is detected, mycelium adapts automatically — no flags needed. Commit notes get a `targets-change` edge (stable across jj rewrites). `read` falls back to change_id lookup when the commit OID changes. Prefer notes on files over commits — blob OIDs survive rewrites, commit OIDs don't. Run `mycelium.sh help` for jj-specific guidance.
