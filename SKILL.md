---
name: mycelium
description: >
  Hidden layer of structured git notes for agent collaboration. When working in any
  git repo, check for notes on objects you touch before acting, and leave notes after
  meaningful work. Uses git notes directly — helper script and workflow scripts included.
---

# Mycelium

Structured notes attached to git objects via `refs/notes/mycelium`.

**Before working on a file, check for its note. After meaningful work, leave a note.**

That’s the whole contract. Mycelium is the storage layer. Richer arrival / history workflows can live in skill scripts.

## On arrival

Start every session with:

```bash
mycelium.sh find constraint                 # project principles & rules
mycelium.sh find warning                    # known fragile things
scripts/context-workflow.sh <file>          # recommended arrival workflow (repo checkout)
```

If you only have the runtime file and not this repo checkout, do the same workflow manually:

```bash
mycelium.sh read <file>                     # exact note on current object
mycelium.sh read HEAD                       # current commit note
# plus raw git notes show on parent dirs / root as needed
```

Before leaving:

```bash
mycelium.sh note HEAD -k context -m "What I did and why."
mycelium.sh note <changed-file> -k <kind> -m "What future agents should know."
```

If you made a decision, use `kind decision` and add a `tested-by` edge to the test that validates it. If you found something fragile, use `kind warning`.

## Core commands

Use these as the protocol-ish primitives:

```bash
mycelium.sh note [target] -k <kind> -m <body>   # write
mycelium.sh read [target]                        # read exact note on current object
mycelium.sh follow [target]                      # read + resolve edges
mycelium.sh refs [target]                        # inbound references
mycelium.sh find <kind>                          # search by kind
mycelium.sh kinds                                # vocabulary in use
mycelium.sh list                                 # all annotated objects
mycelium.sh branch [use|merge] [name]            # branch-scoped notes
mycelium.sh doctor                               # graph facts
mycelium.sh dump                                 # everything, greppable
```

## Workflow scripts in this repo

These are recommended workflows, not part of the core CLI:

```bash
scripts/context-workflow.sh <path> [ref]   # current file + parent dirs + current commit
scripts/path-history.sh <path> [ref]       # older file notes via git history
scripts/note-history.sh <target>           # note overwrite history via notes ref
```

Use them when you want richer context, but keep in mind they are recipes built on top of git + mycelium primitives.

`mycelium.sh compost` still exists as an explicit stale/renew lifecycle for repos that want it, but the simpler default is to use git-native history first and write a fresh current note when older context still matters.

## Patterns

Three patterns cover most usage.

### Pattern 1: One ref accumulates many notes

A file can collect notes from different agents over time.

```bash
mycelium.sh note src/auth.ts -k summary -m "Handles OAuth2 refresh flow."
mycelium.sh note src/auth.ts -k warning -m "Token refresh has a race condition."
mycelium.sh refs src/auth.ts
```

When you need older notes on that file, use git history rather than a special core lifecycle command:

```bash
scripts/path-history.sh src/auth.ts
```

### Pattern 2: One note connects many refs

A single note can link to multiple objects via edges.

```bash
mycelium.sh note SKILL.md -k decision -t "Packaged as an agent skill" \
  -e "depends-on blob:$(git rev-parse HEAD:README.md)" \
  -m "The skill teaches agents the convention on-demand."

mycelium.sh follow SKILL.md
```

Use this whenever a note’s meaning involves more than one object.

### Pattern 3: Planning graph

Use `depends-on` edges to structure planned work.

```bash
mycelium.sh note src/auth.ts -k context -t "Planned: fix race condition" \
  -m "Need mutex around token refresh. See warning note."

mycelium.sh note src/http.ts -k context -t "Planned: retry after refresh" \
  -m "HTTP client should retry once after auth refresh."

mycelium.sh note HEAD -k context -t "Plan: auth hardening" \
  -e "depends-on blob:$(git rev-parse HEAD:src/auth.ts)" \
  -e "depends-on blob:$(git rev-parse HEAD:src/http.ts)" \
  -m "Two files need coordinated changes."
```

## Check for notes

```bash
mycelium.sh read path/to/file.ts              # exact note on current object
mycelium.sh follow HEAD                       # note + where its edges lead
mycelium.sh refs path/to/file.ts              # all notes pointing at target
mycelium.sh find decision                     # all decisions
mycelium.sh find constraint                   # all constraints
git log --notes=mycelium --oneline -20        # recent commits with notes
```

Or with raw git:

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

Every target has different stability.

| Target | Stable? | Use when |
|--------|---------|----------|
| `path/to/file` | ✓ findable by path even if file changes | Note is about the file |
| `$(git rev-parse HEAD:file)` | pinned to this exact blob OID | Note is about this specific version |
| `.` | ✓ project-level, always findable | Note applies to the whole repo |
| `HEAD` | pinned to commit OID (jj: survives via change_id) | Note is about this change |
| `src/dir/` | ✓ findable by path | Note is about the module |

**Default: use paths.** Most notes are about files, not specific versions. The path edge keeps them findable. Use raw OIDs only when you mean “this exact content.”

## Note format

```text
kind decision
title Short label
edge explains commit:abc123...
edge targets-path path:src/auth/retry.ts

Free-form body. Markdown encouraged.
```

**Headers**: `kind` (required), `edge`, `title`, `status`

**Kinds**: `decision` · `context` · `summary` · `warning` · `constraint` · `observation` · `value` · `todo` — or invent your own.

**Edge types**: `explains` · `applies-to` · `depends-on` · `warns-about` · `targets-path` · `targets-treepath` — or invent your own.

**Targets**: `commit:<oid>` · `blob:<oid>` · `tree:<oid>` · `path:<filepath>` · `note:<oid>`

## Note history

There is no special `supersedes` chain in the note body. Overwrite history lives in git itself on the notes ref.

```bash
scripts/note-history.sh path/to/file.ts
```

Or raw git:

```bash
OID=$(git rev-parse HEAD:path/to/file.ts)
FANOUT="${OID:0:2}/${OID:2}"
git log -p refs/notes/mycelium -- "$FANOUT"
```

## Historical notes for a file

If you want older notes on a file path, use git history:

```bash
scripts/path-history.sh src/auth.ts
```

If an older note still matters, write a fresh current note that carries forward the relevant insight.

## Slots

Multiple tools or agents can write notes on the same object without obliteration. Each slot is a named lane backed by its own notes ref.

```bash
mycelium.sh note src/auth.ts --slot skeleton -k observation -m "Structure."
mycelium.sh note src/auth.ts --slot enricher -k summary -m "Context."
mycelium.sh read src/auth.ts --slot skeleton
```

**Rules:**
- `read` / `follow` use the default slot unless `--slot` is given
- `find` / `kinds` / `doctor` / `prime` aggregate all slots
- Reserved names: `main`, `default`

## Setup (once per clone)

```bash
mycelium.sh activate        # notes visible in git log
mycelium.sh sync-init       # notes travel with fetch/push
mycelium.sh repo-id init    # durable repo identity
mycelium.sh zone init       # confidentiality zone
mycelium.sh export f -a internal
mycelium.sh import remote --as lib
```

## jj+git colocated repos

If `.jj/` is detected, mycelium adapts automatically — no flags needed. Commit notes get a `targets-change` edge (stable across jj rewrites). `read` falls back to change_id lookup when the commit OID changes. Prefer notes on files over commits — blob OIDs survive rewrites, commit OIDs don’t.

When jj rewrites commits (amend, rebase, squash), notes on old OIDs become orphaned. Use `migrate` to bulk-reattach them:

```bash
mycelium.sh migrate --dry-run
mycelium.sh migrate
mycelium.sh migrate --map mapping.txt
```

Run `mycelium.sh help` for jj-specific guidance.
