#!/usr/bin/env bash
# mycelium test suite
# Runs in a temporary git repo. Tests the actual tool against real git objects.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MYCELIUM="$REPO_ROOT/mycelium.sh"
COMPOST_WORKFLOW="$REPO_ROOT/scripts/compost-workflow.sh"
INSTALLER="$REPO_ROOT/install.sh"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- test harness ---

assert() {
  local name="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF -- "$expected"; then
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
  if echo "$actual" | grep -qF -- "$unexpected"; then
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
out=$($MYCELIUM note -f -k context -m "Default target test")
assert "note defaults to HEAD" "$COMMIT" "$out"

# Auto-edge: commit gets 'explains'
out=$($MYCELIUM read)
assert "auto-edge explains on commit" "edge explains commit:$COMMIT" "$out"
assert "kind header present" "kind context" "$out"

# File path as target
out=$($MYCELIUM note -f src/auth/retry.ts -k summary -m "Retry module summary")
assert "file path resolves to blob" "$BLOB_RETRY" "$out"

# Auto-edges on blob: applies-to + targets-path
out=$($MYCELIUM read src/auth/retry.ts)
assert "auto-edge applies-to on blob" "edge applies-to blob:$BLOB_RETRY" "$out"
assert "auto-edge targets-path on blob" "edge targets-path path:src/auth/retry.ts" "$out"

# Directory path as target
out=$($MYCELIUM note -f src/auth -k constraint -m "All calls must be retryable")
assert "dir path resolves to tree" "$TREE_AUTH" "$out"

# Auto-edges on tree: applies-to + targets-treepath
out=$($MYCELIUM read src/auth)
assert "auto-edge applies-to on tree" "edge applies-to tree:$TREE_AUTH" "$out"
assert "auto-edge targets-treepath on tree" "edge targets-treepath treepath:src/auth" "$out"

# Explicit edge alongside auto-edges
out=$($MYCELIUM note -f README.md -k summary -e "depends-on blob:$BLOB_RETRY" -m "Readme note")
out=$($MYCELIUM read README.md)
assert "explicit edge preserved" "edge depends-on blob:$BLOB_RETRY" "$out"
assert "auto-edge still present" "edge applies-to blob:$BLOB_README" "$out"

# Title and status
$MYCELIUM note -f HEAD -k decision -t "Use exponential backoff" -s active -m "Decision body" >/dev/null
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
echo "=== Context Workflow Script ==="

# Workflow script walks blob → tree → commit
$MYCELIUM note -f -k context -m "Commit context for context test" >/dev/null
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" src/auth/retry.ts)
assert "context workflow shows exact blob note" "[exact]" "$out"
assert "context workflow shows inherited tree" "[tree]" "$out"
assert "context workflow shows commit" "[commit]" "$out"
assert "context workflow header" "=== workflow context: src/auth/retry.ts" "$out"

out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" does-not-exist.ts 2>&1)
assert "context workflow missing path warns" "(path does not resolve at HEAD: does-not-exist.ts)" "$out"

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
echo "=== Note History ==="

# Overwrite a note and inspect history via git / workflow script
$MYCELIUM note -f src/auth/retry.ts -k summary -m "Updated summary" >/dev/null
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/note-history.sh" src/auth/retry.ts 2>&1)
assert "note history shows latest body" "Updated summary" "$out"
assert "note history shows earlier body" "Retry module summary" "$out"

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
echo "=== Installer ==="

INSTALL_PREFIX="$TMPDIR/install-prefix"
out=$(PREFIX="$INSTALL_PREFIX" bash "$INSTALLER" 2>&1)
assert "installer: reports success" "installed successfully" "$out"
assert "installer: reports target path" "$INSTALL_PREFIX/bin/mycelium.sh" "$out"

if [[ -x "$INSTALL_PREFIX/bin/mycelium.sh" ]]; then
  echo "  ✓ installer: binary exists"
  PASS=$((PASS + 1))
else
  echo "  ✗ installer: binary exists"
  FAIL=$((FAIL + 1))
fi

out=$("$INSTALL_PREFIX/bin/mycelium.sh" help 2>&1)
assert "installer: installed binary runs" "mycelium note" "$out"

PIPE_PREFIX="$TMPDIR/install-pipe-prefix"
out=$(PREFIX="$PIPE_PREFIX" REPO_BASE="file://$REPO_ROOT" bash < "$INSTALLER" 2>&1)
assert "installer: stdin mode succeeds" "installed successfully" "$out"

if [[ -x "$PIPE_PREFIX/bin/mycelium.sh" ]]; then
  echo "  ✓ installer: stdin mode binary exists"
  PASS=$((PASS + 1))
else
  echo "  ✗ installer: stdin mode binary exists"
  FAIL=$((FAIL + 1))
fi

out=$("$PIPE_PREFIX/bin/mycelium.sh" help 2>&1)
assert "installer: stdin mode binary runs" "mycelium note" "$out"

out=$(PREFIX="$INSTALL_PREFIX" bash "$INSTALLER" 2>&1)
assert "installer: idempotent" "installed successfully" "$out"

echo ""
echo "=== Body from stdin ==="

echo "Stdin body content" | $MYCELIUM note -f HEAD -k observation >/dev/null
out=$($MYCELIUM read)
assert "stdin body captured" "Stdin body content" "$out"

echo ""
echo "=== Git-Native Note History ==="

# Write a note, overwrite it, verify history is preserved in the notes ref
$MYCELIUM note -f README.md -k observation -m "First version." >/dev/null
$MYCELIUM note -f README.md -k observation -m "Second version." >/dev/null
$MYCELIUM note -f README.md -k observation -m "Third version." >/dev/null
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/note-history.sh" README.md 2>&1)
assert "note history: latest body present" "Third version." "$out"
assert "note history: middle body present" "Second version." "$out"
assert "note history: first body present" "First version." "$out"

# Notes ref has commit history
out=$(git log --oneline refs/notes/mycelium | wc -l)
assert_not "notes ref has commit history" "0" "$out"

echo ""
echo "=== Historical File Notes ==="

# Annotate a file, then change it
echo "version 1" > stalefile.ts
git add stalefile.ts
git commit -q --no-verify -m "add stalefile"
$MYCELIUM note -f stalefile.ts -k warning -t "Fragile parsing" -m "Do not touch without tests." >/dev/null

echo "version 2" > stalefile.ts
git add stalefile.ts
git commit -q --no-verify -m "modify stalefile"

# read now shows only the current object; history is a workflow script
out=$($MYCELIUM read stalefile.ts)
assert "historical notes: read no longer surfaces old blob note" "(no mycelium note)" "$out"
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/path-history.sh" stalefile.ts)
assert "historical notes: history script finds original note" "Fragile parsing" "$out"
assert "historical notes: history script marks history" "[history]" "$out"

# The optional [ref] argument should bound the walk
cp stalefile.ts refbound.ts
git add refbound.ts
git commit -q --no-verify -m "add refbound"
$MYCELIUM note -f refbound.ts -k summary -t "Refbound v1" -m "first" >/dev/null

echo "refbound v2" > refbound.ts
git add refbound.ts
git commit -q --no-verify -m "update refbound"
$MYCELIUM note -f refbound.ts -k summary -t "Refbound v2" -m "second" >/dev/null

out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/path-history.sh" refbound.ts HEAD~1)
assert "historical notes: ref arg includes older note" "Refbound v1" "$out"
assert_not "historical notes: ref arg excludes newer note" "Refbound v2" "$out"

echo ""
echo "=== Rename (same content) ==="

# Rename without changing content — blob OID stays the same
echo "rename target" > renameme.ts
git add renameme.ts
git commit -q --no-verify -m "add renameme"
$MYCELIUM note -f renameme.ts -k summary -m "Important module." >/dev/null

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
$MYCELIUM note -f deep -k constraint -m "Everything here is experimental." >/dev/null

out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" deep/a/b/c/leaf.ts)
assert "deep inheritance: surfaces parent tree note" "[tree]" "$out"
assert "deep inheritance: shows constraint" "experimental" "$out"

echo ""
echo "=== Root Tree Resolution ==="

# "." should resolve to the root tree
out=$($MYCELIUM read .)
assert "root tree: resolves" "tree:" "$out"

# Write a constraint on root tree
$MYCELIUM note -f . -k constraint -t "Test root principle" -m "Applies to everything." >/dev/null

# Should be readable
out=$($MYCELIUM read .)
assert "root tree: note readable" "Test root principle" "$out"
assert "root tree: has treepath edge" "targets-treepath treepath:." "$out"

# Should surface in workflow context for any file
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" README.md)
assert "root tree: surfaces in workflow context for files" "Test root principle" "$out"
assert "root tree: tagged as [tree] inherited" "[tree]" "$out"

out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" deep/a/b/c/leaf.ts)
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

# Workflow context no longer performs stale-tree recovery; use history when needed
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" README.md)
assert_not "stale root: workflow context stays on current tree" "[stale-tree]" "$out"

echo ""
echo "=== Follow Command ==="

# Setup: note with multiple edges
$MYCELIUM note -f README.md -k decision -t "Multi-edge test" \
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
echo "=== Doctor ==="

out=$($MYCELIUM doctor)
assert "doctor: shows notes count" "notes" "$out"
assert "doctor: shows edges count" "edges" "$out"
assert "doctor: shows kinds" "kinds" "$out"

# Doctor with no notes should report 0
out=$(MYCELIUM_REF=empty-test-ref $MYCELIUM doctor)
assert "doctor: empty ref shows 0" "notes  0" "$out"

# Root tree notes should NOT count as stale in doctor
$MYCELIUM note -f . -k constraint -t "Doctor root test" -m "project-level" >/dev/null
echo "another change" > doctor-test.txt
git add doctor-test.txt
git commit -q --no-verify -m "change tree for doctor test"
out=$($MYCELIUM doctor)
# The root tree note should still be current, not stale
# Total stale should not include root tree notes
assert "doctor: root tree notes are current" "current:" "$out"

echo ""
echo "=== Kinds ==="

out=$($MYCELIUM kinds)
assert "kinds: shows constraint" "constraint" "$out"
assert "kinds: shows counts" "note(s)" "$out"

# Custom kind appears after writing
$MYCELIUM note -f HEAD -k custom-test -m "testing custom kind" >/dev/null
out=$($MYCELIUM kinds)
assert "kinds: custom kind appears" "custom-test" "$out"

echo ""
echo "=== Branch ==="

# Default branch
out=$($MYCELIUM branch)
assert "branch: shows current ref" "mycelium" "$out"
assert "branch: shows notes refs" "notes refs" "$out"

# Switch to branch
out=$($MYCELIUM branch use test-branch)
assert "branch: switch confirms" "mycelium--test-branch" "$out"

# Verify switched
out=$($MYCELIUM branch)
assert "branch: shows new ref" "mycelium--test-branch" "$out"

# Write a note on the branch
$MYCELIUM note -f HEAD -k context -m "branch-scoped note" >/dev/null
out=$($MYCELIUM list)
assert "branch: note visible on branch" "context" "$out"

# Switch back — branch note should not be visible
$MYCELIUM branch use main >/dev/null
out=$($MYCELIUM list)
assert_not "branch: note isolated from main" "branch-scoped note" "$out"

# Merge — non-conflicting (branch has note on object main doesn't)
echo "branch-merge-target" > merge-target.txt
git add merge-target.txt
git commit -q --no-verify -m "merge target file"
$MYCELIUM branch use merge-branch >/dev/null
$MYCELIUM note -f merge-target.txt -k observation -t "from branch" -m "branch note" >/dev/null
$MYCELIUM branch use main >/dev/null

out=$($MYCELIUM branch merge merge-branch)
assert "branch merge: reports count" "Merged 1" "$out"

out=$($MYCELIUM read merge-target.txt)
assert "branch merge: note appears in main" "from branch" "$out"

# Merge — conflicting (both refs have note on same object)
$MYCELIUM note -f merge-target.txt -k summary -t "main version" -m "from main" >/dev/null
$MYCELIUM branch use merge-branch2 >/dev/null
$MYCELIUM note -f merge-target.txt -k warning -t "branch version" -m "from branch" >/dev/null
$MYCELIUM branch use main >/dev/null

$MYCELIUM branch merge merge-branch2 >/dev/null
out=$($MYCELIUM read merge-target.txt)
assert "branch merge conflict: branch wins" "branch version" "$out"
assert_not "branch merge conflict: no supersedes header" "supersedes" "$out"

echo ""
echo "=== Self-Documenting CLI ==="

# help on unknown command shows usage
out=$($MYCELIUM help 2>&1)
assert "help: shows note command" "mycelium note" "$out"
assert "help: shows follow command" "mycelium follow" "$out"
assert "help: shows refs command" "mycelium refs" "$out"
assert "help: shows workflow script guidance" "scripts/context-workflow.sh" "$out"
assert "help: shows doctor command" "mycelium doctor" "$out"
assert "help: shows branch command" "mycelium branch" "$out"
assert "help: shows kinds command" "mycelium kinds" "$out"

# Missing --kind gives clear error
out=$($MYCELIUM note HEAD -m "no kind" 2>&1) || true
assert "error: missing kind" "kind" "$out"

# Docs mention all commands (this is our project's test, not the tool's job)
ROUTE_CMDS=$(sed -n '/^# Route/,/^esac/p' "$MYCELIUM" | grep -oE '^  [a-z-]+\)' | tr -d ' )' | grep -v help)
if [[ -f "$(dirname "$MYCELIUM")/README.md" ]]; then
  README="$(dirname "$MYCELIUM")/README.md"
  for cmd in $ROUTE_CMDS; do
    out=$(grep -c "$cmd" "$README" || true)
    if [[ "$out" -gt 0 ]]; then
      echo "  ✓ README mentions: $cmd"
      PASS=$((PASS + 1))
    else
      echo "  ✗ README missing: $cmd"
      FAIL=$((FAIL + 1))
    fi
  done
fi
if [[ -f "$(dirname "$MYCELIUM")/SKILL.md" ]]; then
  SKILLF="$(dirname "$MYCELIUM")/SKILL.md"
  for cmd in $ROUTE_CMDS; do
    out=$(grep -c "$cmd" "$SKILLF" || true)
    if [[ "$out" -gt 0 ]]; then
      echo "  ✓ SKILL.md mentions: $cmd"
      PASS=$((PASS + 1))
    else
      echo "  ✗ SKILL.md missing: $cmd"
      FAIL=$((FAIL + 1))
    fi
  done
fi

echo ""
echo "=== Stability Hints ==="

# File target shows path hint
out=$($MYCELIUM note -f README.md -k observation -m "path test" 2>&1)
assert "hint: file shows path" "via path:README.md" "$out"

# Raw OID shows pinned hint
BLOB=$(git rev-parse HEAD:README.md)
out=$($MYCELIUM note -f "$BLOB" -k observation -m "pinned test" 2>&1)
assert "hint: OID shows pinned" "pinned to blob" "$out"

# Root tree shows project-level hint
out=$($MYCELIUM note -f . -k observation -m "root test" 2>&1)
assert "hint: root shows project-level" "project-level" "$out"

# Commit shows pinned hint
out=$($MYCELIUM note -f HEAD -k observation -m "commit test" 2>&1)
assert "hint: commit shows pinned" "commit" "$out"

echo ""
echo "=== jj Detection ==="

# Simulate jj colocated repo
mkdir -p .jj

# Help should show jj section
out=$($MYCELIUM help 2>&1)
assert "jj: help shows colocated" "jj+git colocated" "$out"

# Doctor should report jj
out=$($MYCELIUM doctor 2>&1)
assert "jj: doctor shows jj" "jj" "$out"

# Note creation works even without jj binary
out=$($MYCELIUM note -f HEAD -k observation -m "jj test" 2>&1)
assert "jj: note succeeds" "$(git rev-parse HEAD)" "$out"

# Clean up
rm -rf .jj

echo ""
echo "=== Compost ==="

# Setup: create a file, note it, change the file so note goes stale
echo "original content" > compost-target.ts
git add compost-target.ts && git commit -m "compost target" --quiet
$MYCELIUM note -f compost-target.ts -k summary -t "Compost test note" -m "This is the original." >/dev/null 2>&1

echo "changed content" > compost-target.ts
git add compost-target.ts && git commit -m "change compost target" --quiet

# Verify it's stale
out=$($MYCELIUM doctor 2>&1)
assert "compost: doctor shows stale" "stale:" "$out"

# --dry-run: lists stale notes without acting
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" . --dry-run 2>&1)
assert "compost dry-run: lists stale" "Compost test note" "$out"
assert "compost dry-run: shows kind" "summary" "$out"

# --report: just counts
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" . --report 2>&1)
assert "compost report: shows count" "stale" "$out"

# Compost via agent-native flag (no stdin piping)
BLOB_BEFORE=$(git rev-parse HEAD~1:compost-target.ts)
MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" compost-target.ts --compost >/dev/null 2>&1
out=$(git notes --ref=mycelium show "$BLOB_BEFORE" 2>/dev/null)
assert "compost: note has status composted" "status composted" "$out"
assert "compost: note retains kind" "kind summary" "$out"
assert "compost: note retains title" "Compost test note" "$out"

# Doctor reports composted count
out=$($MYCELIUM doctor 2>&1)
assert "compost: doctor shows composted" "composted:" "$out"

echo ""
echo "=== Compost Renew ==="

# Setup: create file, note it, change file
echo "renew original" > renew-target.ts
git add renew-target.ts && git commit -m "renew target" --quiet
$MYCELIUM note -f renew-target.ts -k warning -t "Renew test note" -m "This warning still applies." >/dev/null 2>&1
OLD_BLOB=$(git rev-parse HEAD:renew-target.ts)

echo "renew changed" > renew-target.ts
git add renew-target.ts && git commit -m "change renew target" --quiet
NEW_BLOB=$(git rev-parse HEAD:renew-target.ts)

# Renew via agent-native flag (no stdin piping)
MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" renew-target.ts --renew >/dev/null 2>&1

# New blob should have the note
out=$(git notes --ref=mycelium show "$NEW_BLOB" 2>/dev/null)
assert "renew: note on new blob" "Renew test note" "$out"
assert "renew: updated applies-to" "applies-to blob:$NEW_BLOB" "$out"

# Old blob should be composted
out=$(git notes --ref=mycelium show "$OLD_BLOB" 2>/dev/null)
assert "renew: old blob composted" "status composted" "$out"

echo ""
echo "=== Compost OID Targeting ==="

# Setup: create file, note it, change file
echo "oid-target original" > oid-target.ts
git add oid-target.ts && git commit -m "oid target" --quiet
$MYCELIUM note -f oid-target.ts -k observation -t "OID target test" -m "Target by OID." >/dev/null 2>&1
OID_BLOB=$(git rev-parse HEAD:oid-target.ts)

echo "oid-target changed" > oid-target.ts
git add oid-target.ts && git commit -m "change oid target" --quiet

# Dry-run shows OID
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" oid-target.ts --dry-run 2>&1)
assert "oid: dry-run shows OID" "${OID_BLOB:0:12}" "$out"

# Compost by OID (agent-native: no interactive prompt, no path batch)
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" "${OID_BLOB:0:12}" --compost 2>&1)
assert "oid: compost by OID succeeds" "composted" "$out"
assert "oid: compost output shows kind" "observation" "$out"

# Verify the note is composted
out=$(git notes --ref=mycelium show "$OID_BLOB" 2>/dev/null)
assert "oid: note has status composted" "status composted" "$out"

# Setup for renew by OID
echo "oid-renew original" > oid-renew.ts
git add oid-renew.ts && git commit -m "oid renew" --quiet
$MYCELIUM note -f oid-renew.ts -k decision -t "OID renew test" -m "Renew by OID." >/dev/null 2>&1
OID_RENEW_OLD=$(git rev-parse HEAD:oid-renew.ts)

echo "oid-renew changed" > oid-renew.ts
git add oid-renew.ts && git commit -m "change oid renew" --quiet
OID_RENEW_NEW=$(git rev-parse HEAD:oid-renew.ts)

# Renew by OID
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" "${OID_RENEW_OLD:0:12}" --renew 2>&1)
assert "oid: renew by OID succeeds" "renewed" "$out"

# New blob has the note
out=$(git notes --ref=mycelium show "$OID_RENEW_NEW" 2>/dev/null)
assert "oid: renewed note on new blob" "OID renew test" "$out"

# Old blob composted
out=$(git notes --ref=mycelium show "$OID_RENEW_OLD" 2>/dev/null)
assert "oid: old blob composted after renew" "status composted" "$out"

echo ""
echo "=== Overwrite Guard ==="

# Write a note, then try to overwrite WITHOUT -f — should fail
echo "owtest" > owtest.ts
git add owtest.ts && git commit -m "overwrite test" --quiet
$MYCELIUM note -f owtest.ts -k context -t "First note" -m "first" >/dev/null 2>&1
out=$($MYCELIUM note owtest.ts -k context -t "Second note" -m "second" 2>&1) || true
assert "guard: blocks overwrite without -f" "already exists" "$out"
assert "guard: shows existing title" "First note" "$out"
assert "guard: suggests -f" "-f" "$out"

# Original note is untouched
out=$($MYCELIUM read owtest.ts)
assert "guard: original note preserved" "First note" "$out"

# With -f, overwrite succeeds and warns
out=$($MYCELIUM note -f owtest.ts -k context -t "Second note" -m "second" 2>&1)
assert "overwrite: shows warning with -f" "overwriting" "$out"
assert "overwrite: shows old title" "First note" "$out"

# New note is in place
out=$($MYCELIUM read owtest.ts)
assert "overwrite: new note in place" "Second note" "$out"

echo ""
echo "=== Slot Topologies: One-to-Many ==="

# Setup: one file, two slots writing different notes on same object
echo "shared-file" > shared.ts
git add shared.ts && git commit -m "shared file" --quiet
SHARED_BLOB=$(git rev-parse HEAD:shared.ts)

# Two different slots note the same file — neither obliterates the other
$MYCELIUM note -f shared.ts --slot skeleton -k observation -t "Skeleton obs" -m "File structure noted." >/dev/null 2>&1
$MYCELIUM note -f shared.ts --slot enricher -k summary -t "Enricher summary" -m "Rich context added." >/dev/null 2>&1

# GROUND TRUTH: verify git refs actually exist with correct content
out=$(git notes --ref=mycelium--slot--skeleton show "$SHARED_BLOB" 2>/dev/null)
assert "slot-git: skeleton ref has note on blob" "kind observation" "$out"
assert "slot-git: skeleton note has correct title" "Skeleton obs" "$out"

out=$(git notes --ref=mycelium--slot--enricher show "$SHARED_BLOB" 2>/dev/null)
assert "slot-git: enricher ref has note on blob" "kind summary" "$out"
assert "slot-git: enricher note has correct title" "Enricher summary" "$out"

# GROUND TRUTH: default ref does NOT have skeleton/enricher notes
out=$(git notes --ref=mycelium show "$SHARED_BLOB" 2>/dev/null || echo "NO_NOTE")
assert "slot-git: default ref untouched by slot writes" "NO_NOTE" "$out"

# Both notes exist — read by slot
out=$($MYCELIUM read shared.ts --slot skeleton 2>&1)
assert "slot: skeleton note exists" "Skeleton obs" "$out"

out=$($MYCELIUM read shared.ts --slot enricher 2>&1)
assert "slot: enricher note exists" "Enricher summary" "$out"

# Default slot still works (no --slot flag)
$MYCELIUM note -f shared.ts -k context -t "Default note" -m "Written to default slot." >/dev/null 2>&1
out=$($MYCELIUM read shared.ts 2>&1)
assert "slot: default note exists" "Default note" "$out"

# GROUND TRUTH: default ref now has the note, slot refs unchanged
out=$(git notes --ref=mycelium show "$SHARED_BLOB" 2>/dev/null)
assert "slot-git: default ref has default note" "Default note" "$out"
out=$(git notes --ref=mycelium--slot--skeleton show "$SHARED_BLOB" 2>/dev/null)
assert "slot-git: skeleton unchanged after default write" "Skeleton obs" "$out"

# Workflow context aggregates all slots by default
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" shared.ts 2>&1)
assert "slot: workflow context shows skeleton" "Skeleton obs" "$out"
assert "slot: workflow context shows enricher" "Enricher summary" "$out"
assert "slot: workflow context shows default" "Default note" "$out"

# Workflow context shows which slot each note is from
assert "slot: workflow context labels skeleton slot" "skeleton" "$out"
assert "slot: workflow context labels enricher slot" "enricher" "$out"

echo ""
echo "=== Slot Topologies: Overwrite Within Slot ==="

# Overwrite within same slot updates that slot only
$MYCELIUM note -f shared.ts --slot skeleton -k observation -t "Updated skeleton" -m "Revised." >/dev/null 2>&1
out=$($MYCELIUM read shared.ts --slot skeleton 2>&1)
assert "slot: overwrite within slot" "Updated skeleton" "$out"
assert_not "slot: old note gone from slot read" "Skeleton obs" "$out"

# Enricher note untouched by skeleton overwrite
out=$($MYCELIUM read shared.ts --slot enricher 2>&1)
assert "slot: enricher survives skeleton overwrite" "Enricher summary" "$out"

echo ""
echo "=== Slot Topologies: Cross-Slot Edges ==="

# A note in one slot can reference a note in another slot via edge
SKEL_BLOB=$(git notes --ref=mycelium--slot--skeleton list "$SHARED_BLOB" 2>/dev/null | cut -d' ' -f1 || true)
$MYCELIUM note -f shared.ts --slot enricher -k summary -t "Enricher v2" \
  -e "incorporates note:$SKEL_BLOB" \
  -m "Built on skeleton's observation." >/dev/null 2>&1
out=$($MYCELIUM follow shared.ts --slot enricher 2>&1)
assert "slot: cross-slot edge exists" "incorporates" "$out"

echo ""
echo "=== Slot Topologies: Doctor Aggregates ==="

out=$($MYCELIUM doctor 2>&1)
assert "slot: doctor counts all slots" "notes" "$out"
# Should show notes from skeleton + enricher + default
# At minimum 3 current notes on shared.ts across 3 slots

echo ""
echo "=== Slot Topologies: Stale Detection Per-Slot ==="

# Change the file — all slots' notes on old blob go stale independently
echo "shared-file-v2" > shared.ts
git add shared.ts && git commit -m "change shared file" --quiet

out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" shared.ts --dry-run 2>&1)
# All three slot notes should show as stale
assert "slot: stale detects skeleton" "Updated skeleton" "$out"
assert "slot: stale detects enricher" "Enricher" "$out"
assert "slot: stale detects default" "Default note" "$out"

echo ""
echo "=== Slot Topologies: Compost Per-Slot ==="

# Compost just the skeleton note, leave enricher and default alone
STALE_SKEL_BLOB=$SHARED_BLOB  # blob before file change
MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" shared.ts --slot skeleton --compost >/dev/null 2>&1

# GROUND TRUTH: skeleton note on old blob has status composted
out=$(git notes --ref=mycelium--slot--skeleton show "$STALE_SKEL_BLOB" 2>/dev/null)
assert "slot-git: skeleton composted in git" "status composted" "$out"

# GROUND TRUTH: enricher note on old blob does NOT have status composted
out=$(git notes --ref=mycelium--slot--enricher show "$STALE_SKEL_BLOB" 2>/dev/null)
assert_not "slot-git: enricher NOT composted" "status composted" "$out"

# GROUND TRUTH: default note on old blob does NOT have status composted
out=$(git notes --ref=mycelium show "$STALE_SKEL_BLOB" 2>/dev/null)
assert_not "slot-git: default NOT composted" "status composted" "$out"

# Skeleton gone from stale list, others remain
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" shared.ts --dry-run 2>&1)
assert_not "slot: skeleton composted, gone from stale" "Updated skeleton" "$out"
assert "slot: enricher still stale" "Enricher" "$out"
assert "slot: default still stale" "Default note" "$out"

# Renew enricher to current blob
MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" shared.ts --slot enricher --renew >/dev/null 2>&1
NEW_SHARED_BLOB=$(git rev-parse HEAD:shared.ts)

# GROUND TRUTH: new blob has enricher note
out=$(git notes --ref=mycelium--slot--enricher show "$NEW_SHARED_BLOB" 2>/dev/null)
assert "slot-git: enricher renewed on new blob" "Enricher v2" "$out"

# GROUND TRUTH: old blob enricher is composted
out=$(git notes --ref=mycelium--slot--enricher show "$STALE_SKEL_BLOB" 2>/dev/null)
assert "slot-git: old enricher blob composted" "status composted" "$out"

out=$($MYCELIUM read shared.ts --slot enricher 2>&1)
assert "slot: enricher renewed to current" "Enricher v2" "$out"

echo ""
echo "=== Slot Topologies: Batch Compost Across Slots ==="

# Setup fresh stale notes across slots
echo "batch-file" > batch.ts
git add batch.ts && git commit -m "batch file" --quiet
BATCH_BLOB=$(git rev-parse HEAD:batch.ts)
$MYCELIUM note -f batch.ts --slot alpha -k observation -t "Alpha note" -m "a" >/dev/null 2>&1
$MYCELIUM note -f batch.ts --slot beta -k observation -t "Beta note" -m "b" >/dev/null 2>&1
$MYCELIUM note -f batch.ts -k context -t "Default batch" -m "c" >/dev/null 2>&1
echo "batch-file-v2" > batch.ts
git add batch.ts && git commit -m "change batch" --quiet

# Batch compost by path (no --slot) = compost across ALL slots
MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" batch.ts --compost >/dev/null 2>&1

# GROUND TRUTH: all three refs have composted status on old blob
out=$(git notes --ref=mycelium--slot--alpha show "$BATCH_BLOB" 2>/dev/null)
assert "slot-git: batch alpha composted" "status composted" "$out"
out=$(git notes --ref=mycelium--slot--beta show "$BATCH_BLOB" 2>/dev/null)
assert "slot-git: batch beta composted" "status composted" "$out"
out=$(git notes --ref=mycelium show "$BATCH_BLOB" 2>/dev/null)
assert "slot-git: batch default composted" "status composted" "$out"

# Verify they're gone from stale listing
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" batch.ts --dry-run 2>&1)
assert_not "slot: batch composted alpha" "Alpha note" "$out"
assert_not "slot: batch composted beta" "Beta note" "$out"
assert_not "slot: batch composted default" "Default batch" "$out"

echo ""
echo "=== Slot Topologies: Find/Kinds Across Slots ==="

# find and kinds should aggregate across all slots
out=$($MYCELIUM find observation 2>&1)
assert "slot: find spans slots" "Updated skeleton" "$out"

out=$($MYCELIUM kinds 2>&1)
assert "slot: kinds spans slots" "observation" "$out"

echo ""
echo "=== Slot Topologies: Backward Compatibility ==="

# Existing notes written without --slot still work
# (they live in refs/notes/mycelium, the default)
echo "legacy-file" > legacy.ts
git add legacy.ts && git commit -m "legacy" --quiet
$MYCELIUM note -f legacy.ts -k context -t "Legacy note" -m "No slot specified." >/dev/null 2>&1
out=$($MYCELIUM read legacy.ts 2>&1)
assert "slot: legacy note readable" "Legacy note" "$out"
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/context-workflow.sh" legacy.ts 2>&1)
assert "slot: legacy note in workflow context" "Legacy note" "$out"

echo ""
echo "=== Slot Topologies: Read Semantics ==="

# read with no --slot returns default slot only on the current object
out=$($MYCELIUM read shared.ts 2>&1)
assert "slot: read no-slot stays on current object" "(no mycelium note)" "$out"
assert_not "slot: read no-slot excludes skeleton" "Skeleton" "$out"
assert_not "slot: read no-slot excludes enricher" "Enricher" "$out"

# Historical notes are now a workflow script
out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/path-history.sh" shared.ts 2>&1)
assert "slot: history script finds default note" "Default note" "$out"
assert "slot: history script finds skeleton note" "Updated skeleton" "$out"

# read with --slot returns that slot only on the current object
out=$($MYCELIUM read shared.ts --slot skeleton 2>&1)
assert "slot: read --slot skeleton stays on current object" "(no mycelium note)" "$out"
assert_not "slot: read --slot skeleton excludes enricher" "Enricher" "$out"

echo ""
echo "=== Slot Topologies: OID Ambiguity ==="

# Setup: same object noted in two slots
echo "ambig-file" > ambig.ts
git add ambig.ts && git commit -m "ambig" --quiet
AMBIG_BLOB=$(git rev-parse HEAD:ambig.ts)
$MYCELIUM note -f ambig.ts --slot red -k observation -t "Red note" -m "r" >/dev/null 2>&1
$MYCELIUM note -f ambig.ts --slot blue -k observation -t "Blue note" -m "b" >/dev/null 2>&1
echo "ambig-v2" > ambig.ts
git add ambig.ts && git commit -m "change ambig" --quiet

# Bare OID compost should error when multiple slots match
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" "${AMBIG_BLOB:0:12}" --compost 2>&1 || true)
assert "slot: bare OID ambiguous errors" "ambiguous" "$out"

# With --slot, it works
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" "${AMBIG_BLOB:0:12}" --slot red --compost 2>&1)
assert "slot: OID + slot compost works" "composted" "$out"

echo ""
echo "=== Slot Topologies: Cross-Slot Independence ==="

# Writing to slot A should never affect the note in slot B
echo "xsuper-file" > xsuper.ts
git add xsuper.ts && git commit -m "xsuper" --quiet
$MYCELIUM note -f xsuper.ts --slot alpha -k observation -t "Alpha" -m "a" >/dev/null 2>&1
$MYCELIUM note -f xsuper.ts --slot beta -k summary -t "Beta" -m "b" >/dev/null 2>&1

# Overwrite alpha — beta must stay untouched
$MYCELIUM note -f xsuper.ts --slot alpha -k observation -t "Alpha v2" -m "a2" >/dev/null 2>&1
out=$($MYCELIUM read xsuper.ts --slot beta 2>&1)
assert "slot: beta survives alpha overwrite" "Beta" "$out"
assert_not "slot: beta body unchanged by alpha overwrite" "Alpha v2" "$out"

echo ""
echo "=== Slot Topologies: Renew Collision ==="

# Renew should only fail if same slot has current note, not other slots
echo "renew-col" > renew-col.ts
git add renew-col.ts && git commit -m "renew-col" --quiet
$MYCELIUM note -f renew-col.ts --slot enricher -k summary -t "Enricher col" -m "e" >/dev/null 2>&1
OLD_RC_BLOB=$(git rev-parse HEAD:renew-col.ts)
echo "renew-col-v2" > renew-col.ts
git add renew-col.ts && git commit -m "change renew-col" --quiet
NEW_RC_BLOB=$(git rev-parse HEAD:renew-col.ts)

# Write a note on current version in default slot
$MYCELIUM note -f renew-col.ts -k context -t "Default current" -m "d" >/dev/null 2>&1

# Renew enricher should succeed even though default has a current note
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" renew-col.ts --slot enricher --renew 2>&1)
assert "slot: renew succeeds despite other slot having current" "renewed" "$out"

echo ""
echo "=== Slot Topologies: Follow Across Slots ==="

# follow with no --slot stays on the current object
out=$($MYCELIUM follow shared.ts 2>&1)
assert "slot: follow no-slot reports no current note" "no mycelium note" "$out"

echo ""
echo "=== Slot Topologies: Unsafe Slot Names ==="

# Reserved/dangerous names should be rejected
out=$($MYCELIUM note -f shared.ts --slot "main" -k context -m "bad" 2>&1 || true)
assert "slot: reject 'main' as slot name" "Error" "$out"

out=$($MYCELIUM note -f shared.ts --slot "default" -k context -m "bad" 2>&1 || true)
assert "slot: reject 'default' as slot name" "Error" "$out"

echo ""
echo "=== Slot Topologies: Prime Shows Slots ==="

out=$($MYCELIUM prime 2>&1)
# Prime should show the agent-native CI checklist and repo notes from all slots
assert "slot: prime shows agent-native ci" "Agent-native CI" "$out"
assert "slot: prime aggregates" "notes" "$out"

echo ""
echo "=== Audit Bug: Prime Slot-Only Repo ==="

# In a repo with ONLY slot notes (no default ref notes), prime must still work
# Bug: prime checked only $REF, missed slot-only repos
echo "prime-only" > prime-only.ts
git add prime-only.ts && git commit -m "prime-only" --quiet
$MYCELIUM note -f prime-only.ts --slot alpha -k observation -t "Alpha only" -m "Only slot note." >/dev/null 2>&1
# Remove any default-ref notes on this blob to simulate slot-only
git notes --ref=mycelium remove "$(git rev-parse HEAD:prime-only.ts)" 2>/dev/null || true
out=$($MYCELIUM prime 2>&1)
assert_not "audit: prime doesn't say 'No mycelium notes'" "No mycelium notes" "$out"
assert "audit: prime sees slot-only notes" "notes" "$out"

echo ""
echo "=== Audit Bug: Compost Report Ignores Tree Notes ==="

# Bug: compost --report only checked targets-path, not targets-treepath
mkdir -p treedir
echo "treefile" > treedir/f.ts
git add treedir && git commit -m "treedir" --quiet
$MYCELIUM note -f treedir/ -k constraint -t "Dir constraint" -m "Rule." >/dev/null 2>&1
echo "treefile-v2" > treedir/f.ts
git add treedir && git commit -m "change treedir" --quiet
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" --report 2>&1)
# Report should count the stale tree note
assert "audit: report counts stale tree notes" "stale" "$out"
# Verify dry-run sees it
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" treedir --dry-run 2>&1)
assert "audit: dry-run sees stale tree note" "Dir constraint" "$out"

echo ""
echo "=== Audit Bug: Git Noise Suppressed ==="

# Bug: compost/renew leaked "Overwriting existing notes for object" from git
echo "noise-file" > noise.ts
git add noise.ts && git commit -m "noise" --quiet
$MYCELIUM note -f noise.ts -k context -t "Noise note" -m "n" >/dev/null 2>&1
echo "noise-v2" > noise.ts
git add noise.ts && git commit -m "change noise" --quiet
out=$(MYCELIUM_REF=mycelium "$COMPOST_WORKFLOW" noise.ts --compost 2>&1)
assert_not "audit: no git noise on compost" "Overwriting existing" "$out"

echo ""
echo "=== Migrate: Dry Run ==="

# Simulate jj rewrite: note on old commit OID with a targets-change edge,
# then the commit gets a new OID but same change_id.
MIGRATE_CID="testmigrate00change00id00000000"
OLD_COMMIT=$(git rev-parse HEAD)

# Create a note with a targets-change edge on current HEAD
git notes --ref=mycelium add -f -m "kind context
title Migrate me
edge explains commit:$OLD_COMMIT
edge targets-change change:$MIGRATE_CID

Body of note to migrate." "$OLD_COMMIT"

# Simulate rewrite: new commit with same tree but different OID
git commit --allow-empty -m "rewritten commit" --quiet
NEW_COMMIT=$(git rev-parse HEAD)

# The note is on OLD_COMMIT. We need a way to resolve change_id -> new commit.
# In real jj, `jj log -r $cid` does this. For testing, we create a fake resolver.
# migrate should accept a mapping file or we mock jj.
# Strategy: create a mapping file (old_oid new_oid change_id) that migrate can consume.
MIGRATE_MAP=$(mktemp)
echo "$OLD_COMMIT $NEW_COMMIT $MIGRATE_CID" > "$MIGRATE_MAP"

# Dry run should report what it would do
out=$($MYCELIUM migrate --dry-run --map "$MIGRATE_MAP" 2>&1)
assert "migrate: dry-run reports reattach" "${OLD_COMMIT:0:12}" "$out"
assert "migrate: dry-run shows new target" "${NEW_COMMIT:0:12}" "$out"
assert "migrate: dry-run shows title" "Migrate me" "$out"
assert "migrate: dry-run does not modify" "dry-run" "$out"

# Verify note is still on old commit (dry-run didn't move it)
out=$(git notes --ref=mycelium show "$OLD_COMMIT" 2>&1)
assert "migrate: note still on old OID after dry-run" "Migrate me" "$out"

# New commit should NOT have a note yet
out=$(git notes --ref=mycelium show "$NEW_COMMIT" 2>&1 || echo "(no note)")
assert "migrate: new OID has no note before migrate" "(no note)" "$out"

echo ""
echo "=== Migrate: Apply ==="

out=$($MYCELIUM migrate --map "$MIGRATE_MAP" 2>&1)
assert "migrate: reports reattach" "reattached" "$out"
assert "migrate: shows count" "1" "$out"

# Note should now exist on new commit
out=$(git notes --ref=mycelium show "$NEW_COMMIT" 2>&1)
assert "migrate: note on new OID" "Migrate me" "$out"
assert "migrate: body preserved" "Body of note to migrate" "$out"
assert "migrate: explains edge updated" "explains commit:$NEW_COMMIT" "$out"
assert "migrate: change edge preserved" "targets-change change:$MIGRATE_CID" "$out"

# Old commit note should be gone (moved, not copied)
out=$(git notes --ref=mycelium show "$OLD_COMMIT" 2>&1 || echo "(no note)")
assert "migrate: old OID note removed" "(no note)" "$out"

echo ""
echo "=== Migrate: Skip Conflicts ==="

# If new commit already has a note, migrate should skip (not clobber)
CONFLICT_CID="testconflict0change00id00000000"
C1=$(git rev-parse HEAD~1)
C2=$(git rev-parse HEAD)

git notes --ref=mycelium add -f -m "kind context
title Existing note
edge explains commit:$C2

Already here." "$C2"

git notes --ref=mycelium add -f -m "kind context
title Orphaned note
edge explains commit:$C1
edge targets-change change:$CONFLICT_CID

Would collide." "$C1"

CONFLICT_MAP=$(mktemp)
echo "$C1 $C2 $CONFLICT_CID" > "$CONFLICT_MAP"

out=$($MYCELIUM migrate --map "$CONFLICT_MAP" 2>&1)
assert "migrate: reports skip on conflict" "skip" "$out"

# Existing note should be untouched
out=$(git notes --ref=mycelium show "$C2" 2>&1)
assert "migrate: existing note preserved" "Existing note" "$out"

# Orphaned note should still be on old OID (not deleted)
out=$(git notes --ref=mycelium show "$C1" 2>&1)
assert "migrate: orphaned note kept on conflict" "Orphaned note" "$out"

echo ""
echo "=== Migrate: Idempotent ==="

# Running migrate again on an already-migrated map should be a no-op
out=$($MYCELIUM migrate --map "$MIGRATE_MAP" 2>&1)
assert "migrate: idempotent run shows 0" "0" "$out"

rm -f "$MIGRATE_MAP" "$CONFLICT_MAP"

echo ""
echo "=== Migrate: Auto (jj) ==="

# When no --map given AND .jj exists, migrate should attempt jj-based resolution.
# Without real jj binary, it should report that jj is unavailable gracefully.
mkdir -p .jj
out=$($MYCELIUM migrate --dry-run 2>&1 || true)
# Should either use jj or report it can't
assert "migrate: auto mode mentions jj or map" "jj" "$out"
rm -rf .jj

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
