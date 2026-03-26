---
name: mycelium
description: >
  Hidden layer of structured git notes for agent collaboration. When working in any git repo:
  READ notes on arrival to understand prior reasoning, decisions, and constraints.
  WRITE notes on departure to leave context for future agents and returning humans.
  Attaches to commits, files (blobs), and directories (trees). No CLI required —
  uses git notes directly. Helper script at mycelium.sh for convenience.
  Activate when: reading/writing code, starting/ending a session, or needing to
  understand why something exists.
---

# Mycelium

A hidden graph of structured notes attached to git objects via `refs/notes/mycelium`.
No database. No tracked files. Just `git notes` with a header+body convention.

## The Rule

**When you read a file, check for its note. When you finish work, leave a note.**

```bash
# Read file + its note
git notes --ref=mycelium show $(git rev-parse HEAD:path/to/file.ts) 2>/dev/null

# Leave a note on the commit you just made
git notes --ref=mycelium add -m 'kind context
edge explains commit:'"$(git rev-parse HEAD)"'

Why I did what I did.' HEAD
```

## Note Format

Headers (key-value lines) + blank line + body (free-form markdown).

```
kind decision
title Normalize retry policy
edge explains commit:abc123...
edge applies-to blob:def456...
edge targets-path path:src/auth/retry.ts

We chose exponential backoff with jitter because the original
linear backoff caused thundering herd on token refresh.
```

### Headers

| Header | Required | Repeatable | Meaning |
|--------|----------|------------|---------|
| `kind` | yes | no | Note type (open vocabulary) |
| `edge` | no | yes | `<type> <target>` — typed reference to another object |
| `title` | no | no | Short human-readable label |
| `status` | no | no | `active` (default), `superseded`, `archived` |
| `supersedes` | no | yes | Blob OID of the note this replaces |

### Kinds (open vocabulary — invent freely)

| Kind | When |
|------|------|
| `decision` | A choice was made and why |
| `context` | Background reasoning for a change |
| `summary` | Overview of a file, directory, or subsystem |
| `warning` | Something fragile, dangerous, or surprising |
| `constraint` | A rule that must be maintained |
| `observation` | Something noticed, no action taken |

### Edge Types (open vocabulary — invent freely)

| Type | Meaning |
|------|---------|
| `explains` | Why this object exists or changed |
| `applies-to` | What this note is about |
| `depends-on` | This note assumes that note/object |
| `warns-about` | Be careful with this |
| `supersedes` | Replaces an older note |
| `targets-path` | References a file path |
| `targets-treepath` | References a directory path |

### Targets

**Git objects** (truth — immutable):
`commit:<oid>`, `blob:<oid>`, `tree:<oid>`, `tag:<oid>`, `note:<oid>`

**Helpers** (ergonomic — resolve via `git rev-parse`):
`path:<filepath>`, `treepath:<dirpath>`

## On Arrival — Get Bearings

```bash
# Recent commits with their reasoning
git log --notes=mycelium --oneline -20

# Note on HEAD
git notes --ref=mycelium show HEAD 2>/dev/null

# Note on a specific file's current blob
BLOB=$(git rev-parse HEAD:src/auth/retry.ts)
git notes --ref=mycelium show "$BLOB" 2>/dev/null

# All active decisions
git notes --ref=mycelium list | while read blob obj; do
  git cat-file -p "$blob" | grep -q '^kind decision' && \
    echo "=== $obj ===" && git cat-file -p "$blob" && echo
done

# Delta — what happened in the note layer recently
git log --notes=mycelium --since="3 hours ago"
```

Or use the helper:

```bash
mycelium.sh log 20              # recent commits with notes
mycelium.sh find decision       # all decisions
mycelium.sh read HEAD           # note on HEAD
mycelium.sh read-path src/auth/retry.ts   # note on file's blob
mycelium.sh dump                # all notes, greppable
```

## On Departure — Leave Context

```bash
# Explain a commit
git notes --ref=mycelium add -m 'kind context
edge explains commit:'"$(git rev-parse HEAD)"'
edge targets-path path:src/auth/retry.ts

Refactored retry logic to use exponential backoff with jitter.' HEAD

# Summarize a file
BLOB=$(git rev-parse HEAD:src/auth/retry.ts)
git notes --ref=mycelium add -m 'kind summary
edge applies-to blob:'"$BLOB"'

Handles retry logic for auth token refresh.
Exponential backoff, max 3 retries, jitter.' "$BLOB"

# Set a constraint on a directory
TREE=$(git rev-parse HEAD:src/auth/)
git notes --ref=mycelium add -m 'kind constraint
edge applies-to tree:'"$TREE"'

All network calls in this subtree must be retryable.
No synchronous blocking calls.' "$TREE"

# Record a decision
git notes --ref=mycelium add -m 'kind decision
title Use YAML for config
edge explains commit:'"$(git rev-parse HEAD)"'
edge targets-path path:src/config.ts

Chose YAML over JSON because config files need comments.' HEAD
```

Or use the helper:

```bash
mycelium.sh note HEAD \
  -k context \
  -e "explains commit:$(git rev-parse HEAD)" \
  -e "targets-path path:src/auth/retry.ts" \
  -m "Refactored retry logic."

mycelium.sh note $(git rev-parse HEAD:src/auth/retry.ts) \
  -k summary \
  -e "applies-to blob:$(git rev-parse HEAD:src/auth/retry.ts)" \
  -m "Handles retry logic for auth token refresh."
```

## Setup (once per clone)

```bash
# Make notes visible in git log
git config --add notes.displayRef refs/notes/mycelium

# Enable sync with remote
git config --add remote.origin.fetch '+refs/notes/mycelium:refs/notes/mycelium'
git config --add remote.origin.push 'refs/notes/mycelium:refs/notes/mycelium'
```

Or: `mycelium.sh activate && mycelium.sh sync-init`

## Supersession

Notes are never edited. To update, create a new note that supersedes the old one.

The old note's blob OID is in `git notes --ref=mycelium list` (first column).

```bash
git notes --ref=mycelium add -f -m 'kind decision
status active
supersedes <old-note-blob-oid>
edge applies-to blob:abc123...

Updated: exponential backoff + circuit breaker.' <object>
```

## Principles

1. **Git notes are the substrate.** Not tracked files. Not a database.
2. **Any object → any object.** Commits, blobs, trees, tags, other notes.
3. **No CLI required.** `git notes` + `git cat-file` + `grep` is sufficient.
4. **Invisible until activated.** GitHub doesn't render notes. Feature, not bug.
5. **Read the note, not just the file.** Context lives beside the content.
6. **Leave breadcrumbs.** Future agents and returning humans need your reasoning.
7. **Open vocabulary.** Kinds and edge types are conventions, not constraints.
