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

## Check for notes

```bash
# On a file you're about to work on
git notes --ref=mycelium show $(git rev-parse HEAD:path/to/file.ts) 2>/dev/null

# On the current commit
git notes --ref=mycelium show HEAD 2>/dev/null

# On a directory
git notes --ref=mycelium show $(git rev-parse HEAD:src/auth) 2>/dev/null

# Recent commits with notes
git log --notes=mycelium --oneline -20
```

Or with the helper:

```bash
mycelium.sh read path/to/file.ts
mycelium.sh context path/to/file.ts    # file + parent dirs + commit
mycelium.sh find decision              # all decisions
mycelium.sh find constraint            # all constraints
```

## Leave notes

```bash
# On a commit (explain why)
git notes --ref=mycelium add -m 'kind context
edge explains commit:'"$(git rev-parse HEAD)"'

Why you did what you did.' HEAD

# On a file (summarize, warn, constrain)
BLOB=$(git rev-parse HEAD:path/to/file.ts)
git notes --ref=mycelium add -m 'kind summary
edge applies-to blob:'"$BLOB"'
edge targets-path path:path/to/file.ts

What this file does and anything worth knowing.' "$BLOB"
```

Or with the helper (auto-resolves paths, auto-adds edges):

```bash
mycelium.sh note -k context -m "Why I did this."                     # HEAD
mycelium.sh note path/to/file.ts -k summary -m "What this does."     # file
mycelium.sh note src/auth/ -k constraint -m "Must be retryable."     # directory
mycelium.sh note -k decision -t "Use YAML" -m "Needs comments."     # decision
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

## Setup (once per clone)

```bash
mycelium.sh activate        # notes visible in git log
mycelium.sh sync-init       # notes travel with fetch/push
```

## All helper commands

```
mycelium.sh note [target] -k <kind> -m <body>   Write (default: HEAD)
mycelium.sh read [target]                        Read (default: HEAD)
mycelium.sh context <path>                       All notes for a path
mycelium.sh find <kind>                          Find by kind
mycelium.sh edges [type]                         List edges
mycelium.sh list                                 All annotated objects
mycelium.sh log [n]                              Recent commits with notes
mycelium.sh dump                                 Everything, greppable
mycelium.sh activate                             Show in git log
mycelium.sh sync-init [remote]                   Configure fetch/push
```
