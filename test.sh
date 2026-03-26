#!/usr/bin/env bash
# mycelium test suite
# Runs in a temporary git repo. Tests the actual tool against real git objects.
set -euo pipefail

MYCELIUM="$(cd "$(dirname "$0")" && pwd)/mycelium.sh"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- test harness ---

assert() {
  local name="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF "$expected"; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_not() {
  local name="$1" unexpected="$2" actual="$3"
  if echo "$actual" | grep -qF "$unexpected"; then
    echo "  ✗ $name (should NOT contain)"
    echo "    unexpected: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  fi
}

assert_count() {
  local name="$1" expected="$2" actual="${3:-}"
  local count
  if [[ -z "$actual" ]]; then
    count=0
  else
    count=$(echo "$actual" | grep -c . 2>/dev/null || echo 0)
  fi
  if [[ "$count" -eq "$expected" ]]; then
    echo "  ✓ $name ($count lines)"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected $expected lines, got $count)"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

# --- setup test repo ---

cd "$TMPDIR"
git init -q
git config user.email "test@test"
git config user.name "test"

mkdir -p src/auth src/http
echo "retry logic" > src/auth/retry.ts
echo "client code" > src/http/client.ts
echo "# readme" > README.md
git add .
git commit -q --no-verify -m "initial commit"

COMMIT=$(git rev-parse HEAD)
BLOB_RETRY=$(git rev-parse HEAD:src/auth/retry.ts)
BLOB_README=$(git rev-parse HEAD:README.md)
TREE_AUTH=$(git rev-parse HEAD:src/auth)
TREE_ROOT=$(git rev-parse HEAD^{tree})

echo ""
echo "=== Note Creation ==="

# Default target is HEAD
out=$($MYCELIUM note -k context -m "Default target test")
assert "note defaults to HEAD" "$COMMIT" "$out"

# Auto-edge: commit gets 'explains'
out=$($MYCELIUM read)
assert "auto-edge explains on commit" "edge explains commit:$COMMIT" "$out"
assert "kind header present" "kind context" "$out"

# File path as target
out=$($MYCELIUM note src/auth/retry.ts -k summary -m "Retry module summary")
assert "file path resolves to blob" "$BLOB_RETRY" "$out"

# Auto-edges on blob: applies-to + targets-path
out=$($MYCELIUM read src/auth/retry.ts)
assert "auto-edge applies-to on blob" "edge applies-to blob:$BLOB_RETRY" "$out"
assert "auto-edge targets-path on blob" "edge targets-path path:src/auth/retry.ts" "$out"

# Directory path as target
out=$($MYCELIUM note src/auth -k constraint -m "All calls must be retryable")
assert "dir path resolves to tree" "$TREE_AUTH" "$out"

# Auto-edges on tree: applies-to + targets-treepath
out=$($MYCELIUM read src/auth)
assert "auto-edge applies-to on tree" "edge applies-to tree:$TREE_AUTH" "$out"
assert "auto-edge targets-treepath on tree" "edge targets-treepath treepath:src/auth" "$out"

# Explicit edge alongside auto-edges
out=$($MYCELIUM note README.md -k summary -e "depends-on blob:$BLOB_RETRY" -m "Readme note")
out=$($MYCELIUM read README.md)
assert "explicit edge preserved" "edge depends-on blob:$BLOB_RETRY" "$out"
assert "auto-edge still present" "edge applies-to blob:$BLOB_README" "$out"

# Title and status
$MYCELIUM note HEAD -k decision -t "Use exponential backoff" -s active -m "Decision body" >/dev/null
out=$($MYCELIUM read)
assert "title header" "title Use exponential backoff" "$out"
assert "status header" "status active" "$out"

echo ""
echo "=== Reading ==="

# read with no args
out=$($MYCELIUM read)
assert "read defaults to HEAD" "commit:${COMMIT:0:12}" "$out"

# read file path shows path in label
out=$($MYCELIUM read src/auth/retry.ts)
assert "read path shows filepath" "(src/auth/retry.ts)" "$out"

# read nonexistent note (use OID directly to avoid path-based stale scan)
echo "new file" > newfile.txt
git add newfile.txt
git commit -q --no-verify -m "add newfile"
NEW_BLOB=$(git rev-parse HEAD:newfile.txt)
out=$($MYCELIUM read "$NEW_BLOB" 2>&1)
assert "read missing note" "(no mycelium note)" "$out"

echo ""
echo "=== Context ==="

# Context walks blob → tree → commit
$MYCELIUM note -k context -m "Commit context for context test" >/dev/null
out=$($MYCELIUM context src/auth/retry.ts)
assert "context shows exact blob note" "[exact]" "$out"
assert "context shows inherited tree" "[tree]" "$out"
assert "context shows commit" "[commit]" "$out"
assert "context header" "=== context: src/auth/retry.ts" "$out"

echo ""
echo "=== Find ==="

out=$($MYCELIUM find summary)
assert "find summary finds blob notes" "blob:" "$out"
assert "find summary shows title or body" "Retry module summary" "$out"

out=$($MYCELIUM find constraint)
assert "find constraint" "tree:" "$out"

out=$($MYCELIUM find nonexistent)
assert_count "find nonexistent returns nothing" 0 "${out:-}"

echo ""
echo "=== Edges ==="

out=$($MYCELIUM edges)
assert "edges lists explains" "edge explains" "$out"
assert "edges lists applies-to" "edge applies-to" "$out"

# Filter by type
out=$($MYCELIUM edges explains)
assert "edges filter works" "edge explains" "$out"
assert_not "edges filter excludes others" "edge applies-to" "$out"

echo ""
echo "=== List ==="

out=$($MYCELIUM list)
assert "list shows commit notes" "commit:" "$out"
assert "list shows blob notes" "blob:" "$out"
assert "list shows tree notes" "tree:" "$out"
assert "list shows kind" "[summary]" "$out"
assert "list shows title" "Use exponential backoff" "$out"

echo ""
echo "=== Dump ==="

out=$($MYCELIUM dump)
assert "dump shows commit label" "commit:" "$out"
assert "dump shows blob label" "blob:" "$out"
assert "dump shows note content" "Retry module summary" "$out"

echo ""
echo "=== Log ==="

out=$($MYCELIUM log 5)
assert "log shows commits" "initial commit" "$out"

echo ""
echo "=== Supersession ==="

# Get the current note blob OID on retry.ts
old_blob=$(git notes --ref=mycelium list "$BLOB_RETRY" | cut -d' ' -f1)
$MYCELIUM note src/auth/retry.ts -k summary --supersedes "$old_blob" -m "Updated summary" >/dev/null
out=$($MYCELIUM read src/auth/retry.ts)
assert "supersedes header present" "supersedes $old_blob" "$out"
assert "new body present" "Updated summary" "$out"

echo ""
echo "=== Activate & Sync Init ==="

out=$($MYCELIUM activate)
assert "activate message" "now visible in git log" "$out"

# Check config was set
out=$(git config --get-all notes.displayRef)
assert "displayRef configured" "refs/notes/mycelium" "$out"

# Sync init (no remote, so will fail — test the config write)
git remote add testremote https://example.com/test.git 2>/dev/null || true
out=$($MYCELIUM sync-init testremote)
assert "sync-init message" "Refspecs added" "$out"
out=$(git config --get-all remote.testremote.fetch)
assert "fetch refspec configured" "refs/notes/mycelium" "$out"

echo ""
echo "=== Body from stdin ==="

echo "Stdin body content" | $MYCELIUM note HEAD -k observation >/dev/null
out=$($MYCELIUM read)
assert "stdin body captured" "Stdin body content" "$out"

echo ""
echo "=== Auto-Supersede Invariant ==="

# Write a note, overwrite it, verify the old one is preserved
$MYCELIUM note README.md -k observation -m "First version." >/dev/null
FIRST_BLOB=$(git notes --ref=mycelium list "$BLOB_README" | cut -d' ' -f1)

$MYCELIUM note README.md -k observation -m "Second version." >/dev/null
out=$($MYCELIUM read README.md)
assert "auto-supersede: new note has supersedes header" "supersedes $FIRST_BLOB" "$out"

# Old blob is still retrievable
out=$(git cat-file -p "$FIRST_BLOB")
assert "auto-supersede: old blob retrievable" "First version." "$out"

# Chain: overwrite again, verify it points to second, which points to first
SECOND_BLOB=$(git notes --ref=mycelium list "$BLOB_README" | cut -d' ' -f1)
$MYCELIUM note README.md -k observation -m "Third version." >/dev/null
out=$($MYCELIUM read README.md)
assert "auto-supersede: chain depth 2" "supersedes $SECOND_BLOB" "$out"
out=$(git cat-file -p "$SECOND_BLOB")
assert "auto-supersede: chain walkable" "supersedes $FIRST_BLOB" "$out"

# Notes ref has commit history
out=$(git log --oneline refs/notes/mycelium | wc -l)
assert_not "notes ref has commit history" "0" "$out"

echo ""
echo "=== Stale Detection ==="

# Annotate a file, then change it
echo "version 1" > stalefile.ts
git add stalefile.ts
git commit -q --no-verify -m "add stalefile"
$MYCELIUM note stalefile.ts -k warning -t "Fragile parsing" -m "Do not touch without tests." >/dev/null

echo "version 2" > stalefile.ts
git add stalefile.ts
git commit -q --no-verify -m "modify stalefile"

# read should find the stale note via path edge
out=$($MYCELIUM read stalefile.ts)
assert "stale: no note on current blob" "(no note on current blob)" "$out"
assert "stale: shows [stale] label" "[stale]" "$out"
assert "stale: shows original note content" "Fragile parsing" "$out"

# context should show it as [stale]
out=$($MYCELIUM context stalefile.ts)
assert "stale context: shows [stale]" "[stale]" "$out"
assert "stale context: blob changed message" "blob changed" "$out"

echo ""
echo "=== Rename (same content) ==="

# Rename without changing content — blob OID stays the same
echo "rename target" > renameme.ts
git add renameme.ts
git commit -q --no-verify -m "add renameme"
$MYCELIUM note renameme.ts -k summary -m "Important module." >/dev/null

git mv renameme.ts renamed.ts
git commit -q --no-verify -m "rename"

# Same blob OID — note should follow automatically
out=$($MYCELIUM read renamed.ts)
assert "rename: note follows (same blob)" "Important module." "$out"

echo ""
echo "=== Deep Inheritance ==="

# Constraint on a parent dir should surface for deeply nested files
mkdir -p deep/a/b/c
echo "leaf" > deep/a/b/c/leaf.ts
git add deep
git commit -q --no-verify -m "deep nesting"
DEEP_TREE=$(git rev-parse HEAD:deep)
$MYCELIUM note deep -k constraint -m "Everything here is experimental." >/dev/null

out=$($MYCELIUM context deep/a/b/c/leaf.ts)
assert "deep inheritance: surfaces parent tree note" "[tree]" "$out"
assert "deep inheritance: shows constraint" "experimental" "$out"

echo ""
echo "=== Root Tree Resolution ==="

# "." should resolve to the root tree
out=$($MYCELIUM read .)
assert "root tree: resolves" "tree:" "$out"

# Write a constraint on root tree
$MYCELIUM note . -k constraint -t "Test root principle" -m "Applies to everything." >/dev/null

# Should be readable
out=$($MYCELIUM read .)
assert "root tree: note readable" "Test root principle" "$out"
assert "root tree: has treepath edge" "targets-treepath treepath:." "$out"

# Should surface in context for any file
out=$($MYCELIUM context README.md)
assert "root tree: surfaces in context for files" "Test root principle" "$out"
assert "root tree: tagged as [tree] inherited" "[tree]" "$out"

out=$($MYCELIUM context deep/a/b/c/leaf.ts)
assert "root tree: surfaces for deeply nested files" "Test root principle" "$out"

# find constraint should discover it
out=$($MYCELIUM find constraint)
assert "root tree: findable via find constraint" "Test root principle" "$out"

echo ""
echo "=== Stale Root Tree ==="

# After a new commit, root tree OID changes — constraint becomes stale
echo "trigger tree change" > stale-test.txt
git add stale-test.txt
git commit -q --no-verify -m "change root tree"

# Exact match should fail (different tree OID now)
out=$($MYCELIUM read .)
assert_not "stale root: current tree has no note" "Test root principle" "$out"

# But context should find it via stale-tree scan
out=$($MYCELIUM context README.md)
assert "stale root: surfaces as stale-tree" "Test root principle" "$out"
assert "stale root: marked as stale" "[stale-tree]" "$out"

echo ""
echo "=== Follow Command ==="

# Setup: note with multiple edges
$MYCELIUM note README.md -k decision -t "Multi-edge test" \
  -e "depends-on blob:$(git rev-parse HEAD:src/auth/retry.ts)" \
  -m "A note pointing at multiple objects." >/dev/null

out=$($MYCELIUM follow README.md)
assert "follow: shows the note" "Multi-edge test" "$out"
assert "follow: shows edges section" "edges" "$out"
assert "follow: resolves applies-to" "applies-to" "$out"
assert "follow: resolves depends-on" "depends-on" "$out"

# Follow on object with no note
out=$($MYCELIUM follow src/http/client.ts)
assert "follow: reports no note" "no mycelium note" "$out"

echo ""
echo "=== Refs Command ==="

# refs should find all notes pointing at README.md
out=$($MYCELIUM refs README.md)
assert "refs: finds note by OID" "Multi-edge test" "$out"

# refs on retry.ts should find the depends-on edge
out=$($MYCELIUM refs src/auth/retry.ts)
assert "refs: finds inbound depends-on" "Multi-edge test" "$out"
assert "refs: shows the edge" "depends-on" "$out"

echo ""
echo "=== Cross-Platform ==="

# No GNU-specific flags in sed, grep, or awk
out=$(grep -rn "sed -[iE]" "$MYCELIUM" || true)
assert_count "no GNU sed -i or -E" 0 "$out"

out=$(grep -rn "grep -P" "$MYCELIUM" || true)
assert_count "no grep -P (perl regex)" 0 "$out"

# Only bash builtins + POSIX coreutils + git + mktemp
# Extract external commands from the script
externals=$(grep -ohE '\b(date|stat|readlink|realpath|xargs|tee)\b' "$MYCELIUM" || true)
assert_count "no non-portable externals" 0 "$externals"

echo ""
echo "=== Self-Documenting CLI ==="

# help on unknown command shows usage
out=$($MYCELIUM help 2>&1)
assert "help: shows note command" "mycelium note" "$out"
assert "help: shows follow command" "mycelium follow" "$out"
assert "help: shows refs command" "mycelium refs" "$out"
assert "help: shows context command" "mycelium context" "$out"

# Missing --kind gives clear error
out=$($MYCELIUM note HEAD -m "no kind" 2>&1) || true
assert "error: missing kind" "kind" "$out"

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
