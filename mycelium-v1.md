# Mycelium: Git-Native Metadata Graph

## Specification v1

---

## 0. Metaphor

The codebase is a forest floor. The visible surface — files, commits, branches — is what you see.
Beneath it runs a **mycelial network**: a substrate of notes, decisions, edges, and indices
that connects everything to everything else through Git's own object graph.

**Bearings** tells you where you are on the surface.
**Delta** tells you what changed while you were away.
**Mycelium** is the network that makes both possible.

The substrate is **Git notes** — a hidden, underutilized feature of Git that attaches
metadata to objects without rewriting them. Mycelium turns that attachment mechanism
into a full graph database that travels with the repo.

---

## 1. Goal

Build a deterministic, Git-native metadata graph for repositories.

- The **truth layer** is Git's own object graph and ref namespace.
- The **ergonomic layer** adds helper references, traversal rules, and derived indices.
- The ergonomic layer never replaces the truth layer.
- No tracked working-tree files are touched.
- No external database is required.
- Everything is stored as Git objects and refs.

---

## 2. Design Principles

### 2.1 Four Layers

The architecture has exactly four layers. Each has a clear role and clear boundaries.

| Layer | Role | Mutable? | Authoritative? |
|-------|------|----------|----------------|
| **Storage** | What Git actually stores: objects, refs, notes | Objects: no. Refs: yes. | Yes |
| **Semantic** | What the tool understands: entities, edges, lifecycle | Via new versions | Yes |
| **Resolution** | How helpers become objects at a chosen scope | Per query | No |
| **Derived** | Reverse indices, caches, summaries | Rebuilt | No |

### 2.2 Hard Invariants

1. **Truth is always Git-addressed.**
   Valid truth identifiers: `blob:<oid>`, `tree:<oid>`, `commit:<oid>`, `tag:<oid>`, `ref:<full-refname>`, `note:<oid>`.

2. **Notes are immutable.**
   Editing a note creates a new note blob that `supersedes` the old one. The old blob is never mutated.

3. **Every note has exactly one primary anchor.**
   No free-floating notes in the core model. Every note is grounded on a concrete Git object.

4. **Helper references are selectors, not evidence.**
   `path:`, `treepath:`, `branch:` are resolution inputs, never canonical identities.

5. **Every helper resolution is explicit about context.**
   The system never silently assumes rename-following, symbol heuristics, or ambient repo state.

6. **Derived state is rebuildable.**
   Indices, caches, summaries, and projections must never be the only copy of information.

7. **Lifecycle state and query-time relevance are distinct.**
   A note's semantic status (active/superseded/archived) is independent of its query-time classification (exact/contextual/inherited/orphaned).

8. **Refs encode operational policy, not semantic taxonomy.**
   Namespace boundaries follow merge/display/rewrite/sync behavior, not note kinds.

---

## 3. Identity Model

This is the foundation. Three distinct identity tiers, each answering a different question.

### 3.1 Binding Identity

**"What object is this note attached to, and in which namespace?"**

A binding is the Git-native attachment: notes ref X annotates object Y.

```
binding = (notes_ref, annotated_object)
```

Example: the attachment of notes to `commit:abc123` in `refs/notes/authored`.

Bindings are mutable — the content at that slot can change when the notes ref advances.

### 3.2 Entity Identity

**"What logical note is this — the decision, the review, the constraint?"**

An entity is the logical note a human or agent means. It has a **stable identity** that
survives content edits.

Entity identity is the combination of:
- The **primary anchor** (the Git object the note is grounded on)
- A **stable ID** (content-hash of the canonical first version, or a declared slug for named entities)

```
entity = note:<stable-id>
```

The stable ID is assigned at creation time and never changes, even as the note's content evolves.
For content-addressed entities, the stable ID is the blob OID of the initial version.
For named entities (high-value decisions, constraints), an optional human-readable slug may be used.

### 3.3 Version Identity

**"What exact serialized content am I looking at right now?"**

A version is the immutable blob that currently fills the entity's slot.

```
version = blob:<oid>
```

Fully content-addressed. Two notes with identical content have identical version identity.

### 3.4 Why This Matters

Edges must declare which tier they target:

```json
{"type": "depends_on", "to": "note:retry-queue-policy"}
```
→ targets the **entity** (logical note, survives edits)

```json
{"type": "audits_version", "to": "blob:7f3c..."}
```
→ targets the **version** (exact content, immutable)

The default for note-to-note edges is entity identity.
Version identity is used only when exactness matters (audit, attestation, evidence).

---

## 4. Object Reference Scheme

### 4.1 Truth-Layer References (Canonical)

These are the only fully stable anchors. They address immutable Git objects or mutable ref pointers.

| Reference | Resolves to | Immutable? |
|-----------|-------------|------------|
| `blob:<oid>` | Git blob | Yes |
| `tree:<oid>` | Git tree | Yes |
| `commit:<oid>` | Git commit | Yes |
| `tag:<oid>` | Git annotated tag object | Yes |
| `note:<stable-id>` | Logical note entity | Identity: yes. Content: no. |
| `ref:<full-refname>` | Current target of a Git ref | No |

### 4.2 Helper References (Ergonomic)

These are contextual selectors. They must always be resolved against an explicit scope.

| Helper | Meaning | Example |
|--------|---------|---------|
| `path:<filepath>` | File path in working tree | `path:src/auth/retry.ts` |
| `treepath:<dirpath>` | Directory path | `treepath:src/auth/` |
| `branch:<name>` | Branch shorthand | `branch:main` |

**Deferred to post-v1:**
| Helper | Reason for deferral |
|--------|-------------------|
| `symbol:<name>` | Requires language-server/indexing semantics |
| `glob:<pattern>` | Expansion rules need precise definition |

### 4.3 Floating vs Bound Helpers

A helper may be stored in two forms:

**Floating** (resolved at query time in current context):
```json
{"type": "targets_path", "to": "path:src/auth/retry.ts"}
```

**Bound** (pinned to a specific revision):
```json
{"type": "targets_path", "to": "path:src/auth/retry.ts", "at": "commit:abc123"}
```

Floating helpers keep notes relevant as the codebase evolves.
Bound helpers preserve exact historical grounding when needed.

### 4.4 Object ID Rules

- Always use **full object IDs**, never abbreviated.
- Treat OIDs as opaque byte sequences.
- For cross-repo or export contexts, allow algorithm qualification: `sha1:<oid>` or `sha256:<oid>`.

---

## 5. Storage Model

### 5.A — Note Entity Catalog

**What**: The authoritative store for note content blobs.

**Where**: `refs/mycelium/catalog`

**Layout**: A sharded Git tree, keyed by entity stable ID:

```
<first-2-chars>/<remaining-chars>.json
```

Example: entity `7f3cab91de...` lives at `7f/3cab91de....json`

For named entities (slugs), use the slug directly:

```
named/retry-policy-normalization.json
```

**Properties**:
- Content is immutable blobs
- Layout is a Git tree
- History is via the backing ref's commit chain
- No tracked working-tree files
- This ref is the authoritative record of what notes exist

**Used for**:
- Decisions spanning many objects
- Architecture constraints
- Subsystem summaries
- Migration trackers
- Long-lived audit records
- Any note that is a first-class graph node

### 5.B — Attachment Manifests

**What**: Git notes refs that map Git objects to the set of note entities attached to them.

**Where**: `refs/notes/mycelium/authored`, `refs/notes/mycelium/generated`

**Why manifests?** Git notes allows exactly one note per object per notes ref.
Instead of storing the full note body in that slot, store a **manifest** — a small
document listing entity IDs attached to that object in this namespace.

**Manifest format**:
```
mycelium-manifest v1
note:7f3cab91de...
note:a91def4523...
note:retry-policy-normalization
```

Rules:
- First line is `mycelium-manifest v1` (format version)
- Subsequent lines are entity references, one per line
- Sorted lexicographically
- No duplicates
- LF line endings
- No trailing newline

**Why this works**:
- Multiple notes attach to one object in one namespace ✓
- Notes remain first-class entities in the catalog ✓
- Notes refs stay simple and mergeable ✓
- `cat_sort_uniq` merge strategy works naturally ✓

### 5.C — Derived Indices

**What**: Rebuildable lookup structures for traversal performance.

**Where**: `refs/mycelium/index/<name>`

Examples:
- `refs/mycelium/index/reverse` — inbound edge index (object-keyed, stored as notes ref)
- `refs/mycelium/index/path` — path lookup table (helper-keyed, stored as tree ref)
- `refs/mycelium/index/adjacency` — neighborhood cache

**Rules**:
- Explicitly non-authoritative
- Safe to delete and rebuild from catalog + attachment refs
- Object-keyed indices may use notes refs
- Helper-keyed indices use normal Git tree refs (not forced into notes)

### 5.D — Display Projections (Optional)

**What**: Human-readable note summaries for `git log` integration.

**Where**: `refs/notes/mycelium/display`

**Purpose**: If configured via `notes.displayRef`, Git will show these in `git log` and `git show` output.

**Content**: Rendered markdown or plain text summaries of attached notes, generated from the catalog.

**Rules**:
- Purely derived — rebuilt from authoritative state
- One rendered summary per object (fits Git's one-note-per-object model)
- Never the source of truth

---

## 6. Namespace Policy

Refs encode **operational behavior**, not semantic kind.

### 6.1 Authoritative Refs

| Ref | Policy | Merge | Rewrite | Display |
|-----|--------|-------|---------|---------|
| `refs/mycelium/catalog` | Primary note store | Tree merge | N/A | No |
| `refs/notes/mycelium/authored` | Human-authored attachments | `cat_sort_uniq` | Follow rewrites | Via display ref |
| `refs/notes/mycelium/generated` | Machine-generated attachments | Overwrite/rebuild | Follow rewrites | Via display ref |

### 6.2 Derived Refs

| Ref | Policy |
|-----|--------|
| `refs/mycelium/index/*` | Rebuild, never merge manually |
| `refs/notes/mycelium/display` | Rebuild, never merge manually |

### 6.3 Kind Lives in the Payload

The `kind` field in note content handles semantic taxonomy:

```
decision | review | test | constraint | migration | summary |
incident | run | observation | ...
```

New kinds can be added without creating new refs.
Filtering by kind is a query-time concern, not a storage concern.

---

## 7. Note Schema

### 7.1 Canonical Envelope

```json
{
  "schema": "mycelium/v1",
  "entity_id": "note:7f3cab91de...",
  "kind": "decision",
  "title": "Normalize retry policy across auth subsystem",
  "status": "active",

  "primary_anchor": "commit:abc123...",

  "anchors": [
    {"to": "blob:def456..."},
    {"to": "tree:789aaa..."},
    {"to": "path:src/auth/retry.ts"},
    {"to": "path:src/auth/retry.ts", "at": "commit:abc123..."}
  ],

  "edges": [
    {"type": "applies_to", "to": "blob:def456..."},
    {"type": "explains", "to": "commit:abc123..."},
    {"type": "depends_on", "to": "note:retry-queue-policy"},
    {"type": "targets_path", "to": "path:src/auth/retry.ts"},
    {"type": "derived_from", "to": "note:auth-redesign-2026"}
  ],

  "supersedes": ["note:old-retry-decision"],

  "provenance": {
    "tool": "mycelium/0.1",
    "declared_scope": "commit:abc123...",
    "actor": "agent:claude-session-xyz"
  },

  "body": "Human-readable explanation in markdown.\n\nThe retry policy..."
}
```

### 7.2 Field Semantics

| Field | Required? | Meaning |
|-------|-----------|---------|
| `schema` | Yes | Format identifier and version |
| `entity_id` | Yes | Stable entity identity (assigned at creation) |
| `kind` | Yes | Semantic type (open vocabulary) |
| `title` | Yes | Human-readable title |
| `status` | Yes | Lifecycle state: `active`, `draft`, `superseded`, `archived`, `invalid` |
| `primary_anchor` | Yes | The one Git object this note is grounded on |
| `anchors` | No | Additional grounding points (structured, with optional `at` binding) |
| `edges` | No | Typed outgoing edges to other graph nodes |
| `supersedes` | No | List of entity IDs this note replaces |
| `provenance` | No | Tool, scope, and actor metadata (only when semantic, not for storage tracking) |
| `body` | No | Free-form content (markdown) |

### 7.3 What Is NOT in the Payload

- **`created_at` / `created_by`**: Git ref history provides this. Only include when semantic event time differs from write time.
- **`updated_at`**: Supersession replaces mutation. There is no "updated."
- **Reverse edges**: These are derived, stored in indices, never in the note itself.
- **Redundant attachment facts**: The binding (notes ref → object) already records attachment. Don't duplicate it in the payload unless exporting.

### 7.4 Determinism Rules

Authoritative payloads must be:
- UTF-8 encoded
- LF line endings (no CR)
- Canonical JSON (no trailing commas, no comments)
- Stable key ordering (alphabetical)
- Stable array ordering (edges sorted by `type` then `to`)
- No duplicate edges
- Full object IDs (never abbreviated)
- Timestamps in ISO 8601 UTC with `Z` suffix

Two notes with identical semantic content must produce identical blobs.

---

## 8. Edge Taxonomy

### 8.1 Core Edge Types

Keep the base set small. Extensions come later.

**Grounding edges** (note → object it describes):

| Edge | Meaning |
|------|---------|
| `applies_to` | Note is directly relevant to this object |
| `scopes_to` | Note's relevance is bounded to this tree/subtree |
| `targets_path` | Note references this file path (floating or bound) |
| `targets_treepath` | Note references this directory path |

**Semantic edges** (note → note, note → object for meaning):

| Edge | Meaning |
|------|---------|
| `explains` | Note explains why this commit/object exists |
| `depends_on` | Note's validity depends on another note |
| `related_to` | Loose semantic relationship |
| `supersedes` | This note replaces an older note (also in top-level field) |
| `derived_from` | This note was produced from another note |
| `evidenced_by` | This claim is supported by the target |

### 8.2 Edge Storage Rules

- **Forward edges** are stored in the note payload.
- **Reverse edges** are computed and stored in derived indices.
- **The attachment binding** (notes ref → object) is an implicit `annotates` edge. Do not redundantly store it in the payload.

### 8.3 Tree Inheritance Is Query Behavior

A note attached to a tree is grounded on that tree.

Surfacing it for files *inside* that tree is a **traversal rule**, not a semantic edge.
The note does not implicitly `applies_to` every descendant blob.

Distinguish:
- "Note is attached to `tree:X`" (storage fact)
- "Query engine surfaced it via ancestor containment" (traversal behavior)
- "Note explicitly says `scopes_to tree:X`" (semantic claim)

---

## 9. Supersession Model

Notes are never mutated in place. "Editing" a note follows this protocol:

1. Create a new note blob with updated content
2. Set `supersedes: ["note:<old-entity-id>"]` in the new note
3. Set `status: "superseded"` in the old note's updated version
4. Update attachment manifests to include the new note
5. Update indices

The old note remains in the catalog. It is reachable, auditable, and its `superseded` status
is both a lifecycle fact and a query-time signal.

**Supersession chains must be acyclic.** `fsck` validates this.

---

## 10. Query-Time Classification

When surfacing notes for a target, classify each result explicitly.
This is independent of the note's lifecycle `status`.

| Classification | Meaning |
|----------------|---------|
| **exact** | A canonical object anchor directly matches the queried object |
| **contextual** | A floating helper anchor matches the current path/ref, but the stored object anchor differs from the current object |
| **inherited** | Note is anchored to an ancestor tree or broader scope containing the target |
| **historical** | Note was exact for an earlier object in the target's history |
| **superseded** | Note is part of a supersession chain and not the active head |
| **orphaned** | All anchors fail to resolve in the available repo state |
| **ambiguous** | Helper resolution is not unique (multiple candidates) |

**Default display ordering**: exact → contextual → inherited → historical → superseded → orphaned

A note that is semantically `active` can be query-time `contextual` (the file changed but the note is still relevant).
A note that is semantically `superseded` is always query-time `superseded` regardless of anchor match.

---

## 11. Resolution Model

**Authored helper refs stay unresolved in storage. Resolution happens at query time.**

### 11.1 Resolution Function

```
resolve(helper, at) → truth-layer reference
```

Examples:
- `resolve(path:src/auth/retry.ts, commit:abc)` → `blob:def456`
- `resolve(treepath:src/auth/, HEAD)` → `tree:789aaa`
- `resolve(branch:main, _)` → `ref:refs/heads/main` → `commit:xyz`

### 11.2 Resolution Context

Every resolution requires an explicit scope. The system never silently uses `HEAD` or working tree state.

CLI tools may default to `HEAD` for ergonomics, but the core API always takes an explicit `at` parameter.

### 11.3 Rename Following

**Not part of core v1.**

Rename detection is heuristic. If included later, it must:
- Be opt-in per query
- Declare the exact algorithm and parameters used
- Never affect stored notes or edges
- Only affect query-time classification and surfacing

---

## 12. Traversal Primitives

Six core operations. Everything else composes from these.

### `resolve(helper, at)`
Resolve helper references in an explicit repo state.

### `attached(object, refs...)`
Return entity IDs from attachment manifests on that object across specified notes refs.

### `neighbors(node, filters...)`
Return direct graph neighbors from:
- Attachment manifests
- Note edges (forward)
- Reverse index (backward)
Filterable by edge type, note kind, note status.

### `closure(seeds, edge_filter, depth)`
Typed graph traversal from seed nodes. BFS with configurable edge filter and depth limit.

### `history(selector, mode)`
Walk Git history and fold note graph results.

Modes (explicit, not inferred):
- `exact-object` — match by object OID only
- `exact-path` — match by path at each historical commit
- ~~`follow-renames`~~ — deferred to post-v1

### `fsck()`
Validate the entire graph:
- All notes refs exist and parse
- Every `note:<id>` in manifests exists in the catalog
- Every object reference resolves in the repo
- Manifest format is valid (sorted, no dupes, correct version header)
- Indices match primary state
- Supersession chains are acyclic
- Helpers have valid syntax
- No orphaned catalog entries (entity exists but no manifest references it)

**`fsck` is not optional. It is a core command.**

---

## 13. Merge Rules

### 13.1 Attachment Manifests

Manifests are line-oriented and sorted. Default merge strategy: **`cat_sort_uniq`**.

Git notes natively supports this strategy. It produces correct results for manifests
because the format is designed for it: sorted lines, no duplicates, idempotent union.

Configure per notes ref:
```bash
git config notes.mergeStrategy cat_sort_uniq
# or per-ref configuration
```

### 13.2 Catalog

The catalog is a normal Git tree. It merges like any other tree.

Conflicts occur only if two branches modify the same entity's blob, which should
be rare because notes are immutable (edits create new entities via supersession).

If a true conflict occurs: **manual/tool-aware merge**. The tool must present both
versions and create a supersession resolution.

### 13.3 Derived Indices

Never merge. Always rebuild.

```bash
mycelium index rebuild
```

---

## 14. Rewrite Rules

Git can copy notes across `amend` and `rebase`, but only for refs configured
in `notes.rewriteRef`. There is no default.

### 14.1 Configuration

```bash
# Authored notes follow rebased commits
git config --add notes.rewriteRef refs/notes/mycelium/authored

# Generated notes follow rebased commits
git config --add notes.rewriteRef refs/notes/mycelium/generated
```

### 14.2 Policy by Namespace

| Ref | Rewrite policy | Rationale |
|-----|---------------|-----------|
| `refs/notes/mycelium/authored` | Follow rewrites | Keep context attached to rewritten commits |
| `refs/notes/mycelium/generated` | Follow rewrites | Same |
| `refs/mycelium/index/*` | Rebuild after rewrite | Indices are derived |
| `refs/notes/mycelium/display` | Rebuild after rewrite | Display is derived |

### 14.3 Rewrite Mode

When a rewritten commit already has notes at the destination, Git's default behavior is
concatenation. For structured manifests, this produces invalid content.

**Configure overwrite mode for manifest refs**, or rebuild manifests after rewrite operations.

---

## 15. Transport

**Without explicit transport configuration, the graph is Git-local only.**

A normal `git clone` and `git fetch` only transfer refs matching the configured
refspecs, which default to `refs/heads/*`. Notes and custom refs are silently excluded.

### 15.1 Required Refspec Configuration

```bash
# Fetch
git config --add remote.origin.fetch '+refs/notes/mycelium/*:refs/notes/mycelium/*'
git config --add remote.origin.fetch '+refs/mycelium/*:refs/mycelium/*'

# Push
git config --add remote.origin.push 'refs/notes/mycelium/*:refs/notes/mycelium/*'
git config --add remote.origin.push 'refs/mycelium/*:refs/mycelium/*'
```

### 15.2 `mycelium sync init`

A first-class command that:
1. Adds the above refspecs to the remote configuration
2. Fetches all mycelium refs
3. Rebuilds derived indices
4. Runs `fsck`

This must be part of the v1 command set. Without it, "Git-native" means "Git-local."

---

## 16. Ergonomic Queries

These are the user/agent-facing workflows built on the traversal primitives.

### 16.1 "Open File" Lookup

User or agent opens `src/auth/retry.ts`:

1. `resolve(path:src/auth/retry.ts, HEAD)` → `blob:current`
2. `attached(blob:current, authored, generated)` → exact notes
3. Walk ancestor trees → inherited notes
4. Search catalog for notes with `targets_path: path:src/auth/retry.ts` → contextual notes
5. Classify each result: exact / contextual / inherited
6. Return ranked, classified results

### 16.2 "Why Does This Exist?"

Given a blob, commit, or path:

1. Show exact notes (status: active)
2. Show parent/tree notes (inherited)
3. Show linked decisions (via `explains` edges)
4. Show superseded notes (collapsed by default)

### 16.3 "What Changed Around Here?" (Delta)

Given a path or tree, across a time range:

1. Walk commit history for that path
2. Collect notes attached to prior blobs/commits
3. Surface stale-but-relevant notes (contextual classification)
4. Highlight newest exact grounding
5. Show new notes created since a given timestamp or commit

**This is the delta query** — the first derivative of the note graph.

### 16.4 "Show Me the Neighborhood"

Given any node:

1. `neighbors(node)` → immediate connections
2. Group by: edge type, object type, note kind
3. Show shortest paths to related commits/files/notes
4. Visualize as adjacency list or graph

### 16.5 "Bearings" (Full Orientation)

The comprehensive status query for returning to a repo after absence:

1. Delta: what notes were created/superseded since last session
2. Active decisions affecting current working paths
3. In-flight work (draft notes, recent agent-generated notes)
4. `fsck` warnings (orphaned notes, stale indices)
5. Summary of graph health

---

## 17. v1 Command Set

### 17.1 Core Commands

| Command | Purpose |
|---------|---------|
| `mycelium note create` | Create a new note entity in the catalog |
| `mycelium note attach <entity> <object>` | Add entity to object's attachment manifest |
| `mycelium note detach <entity> <object>` | Remove entity from object's attachment manifest |
| `mycelium note show <entity>` | Display note content and metadata |
| `mycelium note edit <entity>` | Create new version via supersession |

### 17.2 Graph Commands

| Command | Purpose |
|---------|---------|
| `mycelium graph show <target>` | Show all notes relevant to a path/object |
| `mycelium graph neighbors <node>` | Direct graph neighbors |
| `mycelium graph history <path>` | Walk history with note context |
| `mycelium graph resolve <helper> [--at <ref>]` | Resolve helper to object |
| `mycelium graph closure <seed> [--depth N] [--edge-type T]` | Typed traversal |

### 17.3 Maintenance Commands

| Command | Purpose |
|---------|---------|
| `mycelium index rebuild` | Rebuild all derived indices |
| `mycelium fsck` | Validate entire graph |
| `mycelium sync init [remote]` | Configure refspecs and initial fetch |
| `mycelium sync push [remote]` | Push all mycelium refs |
| `mycelium sync fetch [remote]` | Fetch all mycelium refs |

### 17.4 Orientation Commands

| Command | Purpose |
|---------|---------|
| `mycelium bearings` | Full orientation: where am I, what's active, graph health |
| `mycelium delta [--since <ref\|timestamp>]` | What changed in the note graph since X |

---

## 18. Ref Layout Summary

```
refs/
├── mycelium/
│   ├── catalog                          # Note entity store (tree of blobs)
│   └── index/
│       ├── reverse                      # Inbound edge index
│       ├── path                         # Path lookup table
│       └── adjacency                    # Neighborhood cache
└── notes/
    └── mycelium/
        ├── authored                     # Human-authored attachment manifests
        ├── generated                    # Machine-generated attachment manifests
        └── display                      # Human-readable summaries for git log
```

---

## 19. What Is Deferred Past v1

| Feature | Reason |
|---------|--------|
| `symbol:` helper type | Requires language-server semantics |
| `glob:` helper type | Expansion rules need precise definition |
| Rename-aware history | Heuristic, needs exact parameter specification |
| Cross-repo federation | Transport model needs to mature first |
| Trust/signature overlays | Separate concern |
| Custom edge ontologies | Core set must prove itself first |
| Visualization caches | Derived layer needs real usage data |
| Named anchor refs | Lightweight refs for slug-based entities (nice-to-have, not critical) |

---

## 20. The One-Sentence Version

**Use immutable Git objects as truth, refs as names, notes as attachment manifests pointing
into a content-addressed entity catalog, helper references as scoped selectors, supersession
as the editing model, and rebuildable derived refs for reverse lookup, display, and ergonomics —
with transport, merge, rewrite, and fsck as first-class concerns from day one.**

---

## Appendix A: Example Workflow

### Agent creates a decision note

```bash
# 1. Create the note entity
mycelium note create \
  --kind decision \
  --title "Normalize retry policy" \
  --anchor "commit:abc123" \
  --anchor "path:src/auth/retry.ts" \
  --edge "applies_to blob:def456" \
  --edge "explains commit:abc123" \
  --body "The retry policy should use exponential backoff..."

# Output: Created note:7f3cab91de...

# 2. Attach to relevant objects
mycelium note attach note:7f3cab91de... commit:abc123
mycelium note attach note:7f3cab91de... blob:def456

# 3. Verify
mycelium fsck
```

### Human returns after agent session

```bash
# What happened while I was away?
mycelium delta --since "3 hours ago"

# Output:
# 4 notes created (2 decisions, 1 summary, 1 test)
# 1 note superseded
# 12 new attachments
# Index rebuilt at 14:32 UTC

# Get full orientation
mycelium bearings

# Drill into a specific area
mycelium graph show src/auth/retry.ts

# Output:
# [exact]       decision: "Normalize retry policy" (active)
# [contextual]  summary: "Auth subsystem overview" (active, path match)
# [inherited]   constraint: "All network calls must be retryable" (tree: src/)
# [historical]  decision: "Original retry implementation" (superseded)
```

---

## Appendix B: Manifest Example

Content of a Git note attached to `commit:abc123` in `refs/notes/mycelium/authored`:

```
mycelium-manifest v1
note:7f3cab91de...
note:a91def4523...
note:retry-policy-normalization
```

This means three note entities are attached to that commit in the authored namespace.
The actual note content lives in the catalog at `refs/mycelium/catalog`.
