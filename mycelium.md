# Mycelium

A hidden layer of structured notes in git. The substrate that connects the dots.

## What it is

Git notes attached to git objects, following a minimal convention.
No database. No tracked files. No CLI required. Just `git notes` with a format.

## The format

A note is a blob with **headers** and a **body**, separated by a blank line.

```
kind decision
edge explains commit:abc123
edge applies-to blob:def456
edge depends-on note:ee1a90

Normalize retry policy to exponential backoff.

The original implementation used linear backoff in auth
but exponential in the HTTP client. Unified to exponential
everywhere with jitter.
```

### Headers

Each header is a single line: `key value`.

| Header | Required | Repeatable | Meaning |
|--------|----------|------------|---------|
| `kind` | yes | no | What type of note this is |
| `edge` | no | yes | Typed reference: `<type> <target>` |
| `status` | no | no | Lifecycle: `active` (default), `superseded`, `archived` |
| `supersedes` | no | yes | OID of the note this replaces |
| `title` | no | no | Short human-readable label |

That's it. Five headers. Everything else goes in the body.

### Edges

An edge is: `edge <type> <ref>`

The `<ref>` is any git object, prefixed by its type:

```
edge explains commit:abc123def456...
edge applies-to blob:789aaa...
edge warns-about tree:bbb222...
edge depends-on note:ee1a90...
edge targets-path path:src/auth/retry.ts
```

#### Core edge types

| Type | Meaning |
|------|---------|
| `explains` | Why this object exists or changed |
| `applies-to` | What this note is about |
| `depends-on` | This note assumes that note/object |
| `warns-about` | Be careful with this |
| `supersedes` | Replaces an older note (also a header for direct lookup) |

You can use any edge type you want. These five are conventions, not constraints.

### Targets

A target is `<type>:<oid>` or `<helper>:<value>`.

**Git objects** (truth — immutable):
- `blob:<oid>` — a file at a specific version
- `tree:<oid>` — a directory at a specific version
- `commit:<oid>` — a commit
- `tag:<oid>` — an annotated tag
- `note:<oid>` — another mycelium note (by its blob OID)

**Helpers** (ergonomic — resolved via `git rev-parse`):
- `path:<filepath>` — e.g., `path:src/auth/retry.ts`
- `treepath:<dirpath>` — e.g., `treepath:src/auth/`

Helpers are not truth. They're shortcuts. `path:src/foo.ts` today might be
a different blob than yesterday. To pin it, add a second edge to the resolved blob.

### Body

Everything after the first blank line. Free-form. Markdown encouraged.

### Kinds

Open vocabulary. Use whatever makes sense. Some conventions:

| Kind | When to use |
|------|------------|
| `decision` | A choice was made and why |
| `observation` | Something noticed, no action taken |
| `summary` | Overview of a file, directory, or subsystem |
| `warning` | Something fragile, dangerous, or surprising |
| `constraint` | A rule that should be maintained |
| `context` | Background reasoning for a change |

Agents and humans can invent new kinds freely.

## The namespace

One notes ref: `refs/notes/mycelium`

All notes live here. Kind, status, and any other taxonomy live in the headers, not in ref names.

## Read and write

### Write a note

```bash
git notes --ref=mycelium add -m 'kind context
edge explains commit:'"$(git rev-parse HEAD)"'
edge targets-path path:src/auth/retry.ts

Refactored retry logic to use exponential backoff with jitter.
Touched both the auth retry and HTTP client retry paths.' HEAD
```

### Write a note on any object

```bash
# On a specific blob
BLOB=$(git rev-parse HEAD:src/auth/retry.ts)
git notes --ref=mycelium add -m 'kind summary
edge applies-to blob:'"$BLOB"'

This module handles retry logic for auth token refresh.
Uses exponential backoff with jitter. Max 3 retries.' "$BLOB"

# On a tree (directory-level note)
TREE=$(git rev-parse HEAD:src/auth/)
git notes --ref=mycelium add -m 'kind constraint
edge applies-to tree:'"$TREE"'

All network calls in this subtree must be retryable.
Do not add synchronous blocking calls.' "$TREE"
```

### Read notes

```bash
# Show note on a specific object
git notes --ref=mycelium show HEAD
git notes --ref=mycelium show $(git rev-parse HEAD:src/auth/retry.ts)

# Show recent commits with notes
git log --notes=mycelium --oneline -20

# List all annotated objects
git notes --ref=mycelium list

# Search for decisions
git notes --ref=mycelium list | while read blob obj; do
  content=$(git cat-file -p "$blob")
  if echo "$content" | grep -q '^kind decision'; then
    echo "=== $obj ==="
    echo "$content"
    echo
  fi
done
```

### Make notes visible in git log

```bash
git config --add notes.displayRef refs/notes/mycelium
```

Now `git log` and `git show` display mycelium notes inline. This is the "activation" moment.

## Sync

Notes don't travel with normal clone/fetch/push. Add refspecs:

```bash
# Setup (once per clone)
git config --add remote.origin.fetch '+refs/notes/mycelium:refs/notes/mycelium'
git config --add remote.origin.push 'refs/notes/mycelium:refs/notes/mycelium'

# Then just
git fetch origin
git push origin
```

## Supersession

Notes are never edited. To update a note, create a new one that supersedes it.

```bash
# Original note has blob OID ee1a90...
git notes --ref=mycelium add -m 'kind decision
status active
supersedes ee1a90...
edge applies-to blob:abc123

Updated: use exponential backoff with jitter AND circuit breaker.' <object>
```

The old note stays in git's object store. History is preserved.

## What this gives agents

**On arrival** — read `git log --notes=mycelium` to understand recent reasoning,
active decisions, and warnings. Grep for `kind decision` or `kind constraint`
to find what constrains your work.

**On departure** — write notes explaining what you did and why. Future agents
and returning humans read these to get their bearings.

**The delta** — `git log --notes=mycelium --since="3 hours ago"` shows what
changed in the note layer while you were away.

## What this gives humans

**Nothing, until activated.** Notes are invisible on GitHub. They don't show in diffs,
PRs, or file browsers. Run `git config --add notes.displayRef refs/notes/mycelium`
and suddenly `git log` shows the reasoning layer underneath every commit.

## Extensibility

The format is open by design:

- **New kinds**: just use them. `kind migration`, `kind test-result`, `kind incident`.
- **New edge types**: just use them. `edge blocks note:xyz`, `edge tested-by commit:abc`.
- **New headers**: the parser ignores unknown headers. Add `priority high` or `confidence 0.9` freely.
- **Schema evolution**: if the format ever needs breaking changes, add a `schema` header. Absence means v1.

## Design principles

1. **Git notes are the substrate.** Not tracked files. Not a database. Notes.
2. **Any object can point to any object.** Blobs, trees, commits, tags, other notes.
3. **No CLI required.** Everything works with `git notes`, `git cat-file`, and `grep`.
4. **Invisible until activated.** GitHub doesn't show notes. That's a feature.
5. **Headers are machine-readable. Body is human-readable.** Both matter.
6. **Open vocabulary.** Kinds, edge types, and headers are conventions, not constraints.
7. **Resolution is git's job.** `path:x` at `commit:y` = `git rev-parse y:x`. No abstraction needed.

---

*The mycelium is always there. You just have to look underground.*
