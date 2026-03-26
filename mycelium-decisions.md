# Mycelium: Decision Log

How we arrived at the minimal spec, what we considered, and why we chose what we chose.

---

## Origin

The problem: a human leaves, agents work autonomously for hours, the human returns.
How does the human get oriented? How do agents leave useful context for each other?

The conversation started with metaphors for orientation:

- **Bearings** — where am I? (spatial, calm, implies competence)
- **Delta** — what changed since I was last here? (temporal, the first derivative)
- **Mycelium** — the network underneath that explains WHY things changed

The insight: delta is just the surface. The real value is the **substrate** —
the hidden network of connections, reasoning, and decisions that agents traverse
as they work. The delta is a *manifestation* of what's in the mycelium.

Git notes are that substrate. Hidden, underutilized, attached to any object,
traveling with the repo but invisible on GitHub.

---

## Three Input Sessions

The spec was synthesized from three detailed planning sessions, each approaching
the same problem from different angles. Here are the key ideas each contributed
and where they conflicted.

### Session 1: "Attachment Manifests"

**Key contributions:**
- Manifests pattern: notes refs contain lists of entity IDs, not full note bodies.
  Solves git's one-note-per-object-per-ref limitation.
- `cat_sort_uniq` merge strategy for line-oriented manifests.
- Transport as first-class concern (explicit fetch/push refspecs).
- Rewrite rules (`notes.rewriteRef` configuration for amend/rebase).
- Floating vs bound helpers: `path:x` (resolved at query time) vs `path:x at commit:y` (pinned).
- Supersession model: never mutate, always create new + link.
- Six query-time classifications: exact, contextual, inherited, historical, superseded, orphaned.
- Note identity as `note:<blob-oid>` — fully content-addressed, no separate identity tier.
- Refs encode policy not taxonomy: `shared/review/local` not `decision/test/review`.

**What we kept:** Supersession model. Transport awareness. Floating vs bound helpers.
Content-addressed identity. Policy-over-taxonomy for refs.

**What we cut:** Manifests (deferred — 1:1 is fine to start). Catalog ref. Six-tier
classification (moved to tooling, not protocol). Derived index refs.

### Session 2: "Three-Tier Identity"

**Key contributions:**
- The binding/entity/version distinction: what object is this attached to? What logical
  note is this? What exact content version?
- Four architecture layers: storage, semantic, resolution, derived.
- Standalone entity store via annotated tag objects as stable anchors.
- `notebind:` reference scheme for attachment slots.
- Lifecycle state vs query-time classification as explicitly separate concerns.
- Operational ref splits: `authored/generated/index` by lifecycle, not by kind.
- Hash algorithm awareness for cross-repo contexts.
- `primary_anchor` as required field.
- Object-keyed indices in notes refs, helper-keyed indices in normal tree refs.

**What we kept:** The principle that lifecycle ≠ query relevance (though we moved
classification entirely to tooling). The insight that identity has layers.

**What we cut:** The three-tier identity model (collapsed to: identity = blob OID,
names = refs). The `notebind:` scheme. Tag-based entity anchors. The four-layer
architecture (collapsed to: notes + convention). `primary_anchor` as required field.

### Session 3: "Notes as Graph Nodes"

**Key contributions:**
- Notes are bidirectional graph nodes, not just annotations.
- Ergonomic query recipes: "open file lookup", "why does this exist?",
  "what changed around here?", "show me the neighborhood", "preflight context".
- Three storage classes: attached notes, free graph notes, index/helper notes.
- Traversal primitives: neighbors, resolve, closure, history.
- Reverse lookup as the only nontrivial problem.
- The observation that forward edges are easy (parse payload) but reverse edges
  need indexing.

**What we kept:** Notes as graph nodes (any object pointing to any object).
The ergonomic query ideas (as future tooling, not protocol).

**What we cut:** Three storage classes (just one: notes). Traversal primitives
(tooling, not protocol). Free graph notes as a separate concept.

---

## The 10 Hard Questions

Before v2, we identified 10 questions that stress-tested the design.
Here is each question, what we considered, and what we decided.

### Q1: Manifests vs more refs?

**The problem:** Git notes allows exactly one note per object per notes ref.
If two agents annotate the same commit, you have a collision.

**Options considered:**
- A. Manifests: the note on an object is a list of entity IDs pointing into a catalog.
- B. More refs: `refs/notes/mycelium/session-1`, `refs/notes/mycelium/session-2`, etc.
- C. Accept 1:1 and see if it hurts.

**Decision: C.** Start with 1:1. The common agent case is one note per commit.
If two agents touch the same commit, `git notes append` exists as an escape valve.
Manifests add a custom format layer that fights git-nativeness. More refs proliferate
unboundedly. We'll learn from real usage whether multiplexing is needed.

**What we'd do if it hurts:** Add a second notes ref (`refs/notes/mycelium-overflow`
or per-session refs). Or adopt the manifest pattern from Session 1. But not until
we have evidence.

### Q2: Does the entity catalog need to exist?

**The problem:** Session 1 proposed a sharded tree (`refs/mycelium/catalog`) indexing
all note blobs by OID. Session 2 proposed annotated tags as stable anchors.

**Options considered:**
- A. Sharded blob catalog (Session 1): `refs/mycelium/catalog` with `aa/bbccdd...json`.
- B. Tag-anchored entities (Session 2): `refs/git-notes/anchors/decision/name`.
- C. No catalog. Notes live in notes refs. `git notes list` enumerates them.

**Decision: C.** Git notes refs already provide enumeration. `git notes --ref=mycelium list`
gives you every annotated object and its note blob OID. A separate catalog is a
second index of information that already exists. Cut it.

**Trade-off acknowledged:** Without a catalog, finding all notes of a given kind
requires scanning all note blobs. This is O(n) and fine for hundreds or low thousands
of notes. If it becomes a bottleneck, add a derived index. But that's tooling, not protocol.

### Q3: JSON or header+body format?

**The problem:** Notes need structure for machine-readability. What format?

**Options considered:**
- A. JSON: universal, nested structures, schema validation.
- B. Header+body: git-native convention (matches commit/tag format), grep-friendly,
     diff-friendly, readable in `git notes show` without tooling.
- C. YAML, TOML, or other structured formats.

**Decision: B (header+body).** The deciding test was Q6: can an agent with only `git`
(no custom CLI) read and write useful notes? Headers pass this test. JSON requires
either a parser or careful string escaping. Headers require only `grep`.

Also: JSON has a canonical serialization problem. Key ordering, whitespace, trailing
commas — the v1 spec needed an entire section (§7.4) on determinism rules. Headers
are inherently line-ordered and deterministic. That whole class of problems disappears.

**Trade-off acknowledged:** Headers are flat. You can't represent deeply nested
structures. If complex structured data is needed, it goes in the body as whatever
format the writer chooses. The headers are the machine-readable graph edges.
The body is free-form.

### Q4: Should edges be git tree entries instead of header lines?

**The problem:** Git trees are native graph structures — each entry is (name, mode, oid).
Edges could literally be tree entries, making traversal = `git ls-tree`.

**Options considered:**
- A. Edges as tree entries: a note is a tree object containing edge entries + a body blob.
- B. Edges as header lines in a flat blob.

**Decision: B.** Tree-per-note requires 3 objects per note (tree + blob + commit for history)
vs 1 blob. The write path becomes complex: create blob, create tree referencing it,
create commit on the notes ref. `git notes add -m` no longer works. This fights
the "no CLI required" principle.

Edge traversal via `grep '^edge '` on a blob is fast enough for any realistic note count.

**Trade-off acknowledged:** If the note graph ever reaches millions of edges,
`git ls-tree` traversal would be faster than text parsing. But that's a scale problem
we don't have and may never have.

### Q5: Does note identity need its own tier?

**The problem:** Session 1 said identity = blob OID (content-addressed). Session 2
said identity = stable logical slot (survives edits). Session 3 was ambiguous.

**Options considered:**
- A. Three-tier identity: binding + entity + version (Session 2).
- B. Content-addressed: identity = blob OID, supersession chains for continuity (Session 1).
- C. No explicit identity concept at all. A note is a blob. It has an OID. Use it.

**Decision: C, with a nod to B.** A note is a blob attached to an object. Its identity
is the blob OID. If you supersede it, the new note's `supersedes` header links them.
If you want a human name, create a lightweight ref (`refs/mycelium/names/retry-policy`).

The three-tier model (Session 2) solves real problems but adds cognitive overhead
that isn't justified until we have complex graph traversal needs. Blob OID + supersession
+ optional named refs covers every case with zero new concepts.

**Trade-off acknowledged:** If a note is superseded, edges pointing to the old blob OID
now point to a superseded note. The tool must follow supersession chains to find the
active version. This is a traversal cost we accept in exchange for simpler identity.

### Q6: Must it work without a custom CLI?

**The problem:** If the CLI is the only way to use mycelium, adoption depends on
installing a tool. If raw `git` works, adoption is near-zero friction.

**Decision: Yes. Hard requirement.** Every operation must be possible with `git notes`,
`git cat-file`, `git rev-parse`, `git config`, and `grep`. The header+body format
exists specifically to pass this test.

A custom CLI can add ergonomics (search, graph traversal, pretty output) but must
never be required for basic read/write.

**This was the keystone decision.** It resolved Q3 (headers not JSON), Q10 (no resolution
layer), and shaped the entire minimal spec.

### Q7: What's the GC/pruning story?

**The problem:** Superseded notes stay in git's object store. With prolific agents,
the note history grows unboundedly.

**Options considered:**
- A. Add `mycelium prune` to v1 (removes superseded chain tails).
- B. Defer and observe growth characteristics.
- C. Rely on `git gc` (which handles packfile compression but not notes ref cleanup).

**Decision: B.** We don't know the growth rate yet. Git's packfile compression
is efficient for many small blobs. The notes ref commit history may grow, but
that's also compressible.

Build pruning when we have data showing it's needed.

**What we'd do if it hurts:** `git notes --ref=mycelium prune` already removes
notes for unreachable objects. For superseded chains, a simple script can walk
`supersedes` headers and remove old versions from the notes ref.

### Q8: Fork/clone — is invisible metadata a feature or liability?

**The problem:** GitHub forks don't include notes. Normal clones don't either unless
refspecs are configured. The metadata silently disappears.

**Options considered:**
- A. Add `mycelium export --to-tree` to materialize notes as tracked files.
- B. Accept invisibility as a feature. Document sync setup.
- C. Add a single visible marker (`.mycelium` file or README line).

**Decision: B for now.** Invisibility IS the feature for the primary use case
(agents working in repos the user controls). The sync section of the spec documents
the refspec setup.

**Deferred:** `export --to-tree` for open-source repos where strangers fork.
This is post-v1 tooling.

**Trade-off acknowledged:** A new contributor cloning the repo has no idea mycelium
exists unless told. This is acceptable for agent-native workflows where the repo
owner controls the environment. It's not acceptable for public collaboration.
We'll address it when the use case demands it.

### Q9: Should graph protocol and note format be separate specs?

**The problem:** The protocol ("git objects reference other git objects via notes")
and the format ("header+body with these fields") are different concerns.

**Options considered:**
- A. Two separate spec documents.
- B. One document with clear conceptual separation.
- C. Don't separate — the format IS the protocol.

**Decision: B.** They're conceptually separate but small enough to live in one document.
The spec clearly separates "the format" (headers, body, kinds, edge types) from
"the infrastructure" (notes refs, sync, display activation).

If other tools want to use mycelium notes refs with different payload formats,
the notes ref convention (namespace, sync, display) is reusable independently
of the header+body format.

### Q10: Does the resolution layer belong in the spec?

**The problem:** Session 1 defined `resolve(helper, at)` as an abstraction.
But `path:x at commit:y` is just `git rev-parse y:x`.

**Decision: No resolution layer.** The spec documents the mapping:

| Helper | Git command |
|--------|------------|
| `path:x` at `commit:y` | `git rev-parse y:x` |
| `treepath:x` at `commit:y` | `git rev-parse y:x` |
| `branch:x` | `git rev-parse refs/heads/x` |
| `ref:x` | `git rev-parse x` |

Four lines. Not an abstraction. Just a reference table.

---

## What We Cut (and Why)

### From the 882-line v1 spec

| Feature | Why cut |
|---------|---------|
| Attachment manifests | Premature — 1:1 is fine to start |
| Entity catalog (`refs/mycelium/catalog`) | Redundant — `git notes list` enumerates |
| Sharded tree layout | Optimization without a performance problem |
| Three-tier identity (binding/entity/version) | Cognitive overhead without proven need |
| `notebind:` reference scheme | Over-abstraction |
| Tag-anchored entities | Heavyweight for the common case |
| Six traversal primitives | Tooling, not protocol |
| Seven query-time classifications | Tooling, not protocol |
| Merge strategy specification | Premature — one ref, `cat_sort_uniq` or manual when needed |
| Rewrite rules (`notes.rewriteRef`) | Real concern, but configure-when-needed, not spec |
| Display projections ref | Just use `notes.displayRef` directly |
| Derived index refs | Build when traversal is slow, not before |
| `symbol:` and `glob:` helpers | Need language-server semantics, far from v1 |
| `primary_anchor` as required field | Just attach the note to the object — that IS the anchor |
| `provenance` fields | Git ref history provides provenance |
| `created_at` / `created_by` | Same — git history covers this |
| Schema version in header | Absence = v1. Add `schema` header only if format ever breaks. |
| Formal edge taxonomy | Open vocabulary. Conventions, not constraints. |
| `fsck` command | Important eventually, but protocol shouldn't mandate tooling |
| Named entity refs (`refs/mycelium/names/`) | Sugar. Mention as convention, don't spec. |

### What we preserved

| Feature | Why kept |
|---------|---------|
| Header+body format | Git-native, grep-friendly, no parser needed |
| Any-object-to-any-object edges | Core insight — the graph is between ALL objects |
| Open `kind` vocabulary | Extensibility without spec changes |
| Open edge type vocabulary | Same |
| Supersession model | Immutability matches git's own model |
| Single notes ref | Simplest possible starting point |
| Sync documentation | Notes don't travel by default — this must be explicit |
| Display activation | The "invisible until activated" property |

---

## Key Tensions Acknowledged But Unresolved

These are real concerns we chose not to solve yet. They need observation from real usage.

### Multiple notes on one object

If two agents annotate the same commit, only one note survives per notes ref.
`git notes append` concatenates but breaks structure. We're betting this is
rare enough to defer. If it's not, manifests or multi-ref are the escape hatches.

### Reverse edge traversal

Finding "all notes that reference blob X" requires scanning all notes. This is
O(n) and fine for small-to-medium note counts. A derived reverse index is the
known solution but we don't build it until it's needed.

### Scale characteristics

We don't know how many notes a typical agent session generates, how fast the
notes ref grows, or when grep-based search becomes too slow. The spec is
designed to learn these things, not to pre-optimize for them.

### Cross-repo references

The spec only addresses single-repo graphs. Notes referencing objects in other
repos (e.g., a monorepo split) are not handled. This is a real problem we don't
have yet.

### Supersession chain depth

If a note is superseded 50 times, following the chain to find the active version
is expensive. We don't know if this happens in practice. If it does, a simple
"latest version" index solves it.

---

## The Meta-Decision: Substrate vs Tool

The biggest decision was **where to draw the line between protocol and tooling.**

The v1 spec tried to be both. It specified the format, the storage, the traversal,
the classification, the indices, the CLI commands, the merge strategies, and the
rewrite rules. It was a complete system specification.

The final spec is only the substrate:
- What a note looks like (format)
- Where it lives (notes ref)
- How it travels (sync)
- How it becomes visible (display activation)

Everything else — search, traversal, indexing, classification, CLI ergonomics —
is tooling built on top of an intentionally simple substrate.

The analogy: mycelium (the spec) is the network of hyphae. Mushrooms (the tools)
are what fruits from it. You don't specify mushroom shapes when you're designing
the network.

---

## Lineage

```
Conversation flow:

  "handle" / "bearings" / "pulse"     → orientation metaphors
  "first derivative"                   → delta (what changed)
  "underpinning / mycelium"            → the substrate insight
  "git notes as substrate"             → three detailed planning sessions
  "synthesize into unified spec"       → mycelium-v1.md (882 lines)
  "10 hard questions"                  → stress-tested the design
  "strip to substrate"                 → mycelium.md (final spec)
```

The spec went from 882 lines to ~170. Not because the thinking was wrong,
but because most of it was tooling, not protocol. The thinking is preserved
here for when we need it.
