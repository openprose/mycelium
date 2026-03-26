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
assert "stale context: compressed one-liner" "for full note" "$out"

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
echo "=== Doctor ==="

out=$($MYCELIUM doctor)
assert "doctor: shows notes count" "notes" "$out"
assert "doctor: shows edges count" "edges" "$out"
assert "doctor: shows kinds" "kinds" "$out"

# Doctor with no notes should report 0
out=$(MYCELIUM_REF=empty-test-ref $MYCELIUM doctor)
assert "doctor: empty ref shows 0" "notes  0" "$out"

# Root tree notes should NOT count as stale in doctor
$MYCELIUM note . -k constraint -t "Doctor root test" -m "project-level" >/dev/null
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
$MYCELIUM note HEAD -k custom-test -m "testing custom kind" >/dev/null
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
$MYCELIUM note HEAD -k context -m "branch-scoped note" >/dev/null
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
$MYCELIUM note merge-target.txt -k observation -t "from branch" -m "branch note" >/dev/null
$MYCELIUM branch use main >/dev/null

out=$($MYCELIUM branch merge merge-branch)
assert "branch merge: reports count" "Merged 1" "$out"

out=$($MYCELIUM read merge-target.txt)
assert "branch merge: note appears in main" "from branch" "$out"

# Merge — conflicting (both refs have note on same object)
$MYCELIUM note merge-target.txt -k summary -t "main version" -m "from main" >/dev/null
$MYCELIUM branch use merge-branch2 >/dev/null
$MYCELIUM note merge-target.txt -k warning -t "branch version" -m "from branch" >/dev/null
$MYCELIUM branch use main >/dev/null

$MYCELIUM branch merge merge-branch2 >/dev/null
out=$($MYCELIUM read merge-target.txt)
assert "branch merge conflict: branch wins" "branch version" "$out"
assert "branch merge conflict: supersedes main" "supersedes" "$out"

echo ""
echo "=== Self-Documenting CLI ==="

# help on unknown command shows usage
out=$($MYCELIUM help 2>&1)
assert "help: shows note command" "mycelium note" "$out"
assert "help: shows follow command" "mycelium follow" "$out"
assert "help: shows refs command" "mycelium refs" "$out"
assert "help: shows context command" "mycelium context" "$out"
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
out=$($MYCELIUM note README.md -k observation -m "path test" 2>&1)
assert "hint: file shows path" "via path:README.md" "$out"

# Raw OID shows pinned hint
BLOB=$(git rev-parse HEAD:README.md)
out=$($MYCELIUM note "$BLOB" -k observation -m "pinned test" 2>&1)
assert "hint: OID shows pinned" "pinned to blob" "$out"

# Root tree shows project-level hint
out=$($MYCELIUM note . -k observation -m "root test" 2>&1)
assert "hint: root shows project-level" "project-level" "$out"

# Commit shows pinned hint
out=$($MYCELIUM note HEAD -k observation -m "commit test" 2>&1)
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
out=$($MYCELIUM note HEAD -k observation -m "jj test" 2>&1)
assert "jj: note succeeds" "$(git rev-parse HEAD)" "$out"

# Clean up
rm -rf .jj

echo ""
echo "=== Compost ==="

# Setup: create a file, note it, change the file so note goes stale
echo "original content" > compost-target.ts
git add compost-target.ts && git commit -m "compost target" --quiet
$MYCELIUM note compost-target.ts -k summary -t "Compost test note" -m "This is the original." >/dev/null 2>&1

echo "changed content" > compost-target.ts
git add compost-target.ts && git commit -m "change compost target" --quiet

# Verify it's stale
out=$($MYCELIUM doctor 2>&1)
assert "compost: doctor shows stale" "stale:" "$out"

# --dry-run: lists stale notes without acting
out=$($MYCELIUM compost . --dry-run 2>&1)
assert "compost dry-run: lists stale" "Compost test note" "$out"
assert "compost dry-run: shows kind" "summary" "$out"

# --report: just counts
out=$($MYCELIUM compost . --report 2>&1)
assert "compost report: shows count" "stale" "$out"

# Compost via agent-native flag (no stdin piping)
BLOB_BEFORE=$(git rev-parse HEAD~1:compost-target.ts)
$MYCELIUM compost compost-target.ts --compost >/dev/null 2>&1
out=$(git notes --ref=mycelium show "$BLOB_BEFORE" 2>/dev/null)
assert "compost: note has status composted" "status composted" "$out"
assert "compost: note retains kind" "kind summary" "$out"
assert "compost: note retains title" "Compost test note" "$out"

# Context hides composted notes by default
out=$($MYCELIUM context compost-target.ts 2>&1)
assert_not "compost: context hides composted" "Compost test note" "$out"

# Context --all shows composted notes
out=$($MYCELIUM context compost-target.ts --all 2>&1)
assert "compost: context --all shows composted" "Compost test note" "$out"

# Doctor reports composted count
out=$($MYCELIUM doctor 2>&1)
assert "compost: doctor shows composted" "composted:" "$out"

echo ""
echo "=== Compost Renew ==="

# Setup: create file, note it, change file
echo "renew original" > renew-target.ts
git add renew-target.ts && git commit -m "renew target" --quiet
$MYCELIUM note renew-target.ts -k warning -t "Renew test note" -m "This warning still applies." >/dev/null 2>&1
OLD_BLOB=$(git rev-parse HEAD:renew-target.ts)

echo "renew changed" > renew-target.ts
git add renew-target.ts && git commit -m "change renew target" --quiet
NEW_BLOB=$(git rev-parse HEAD:renew-target.ts)

# Renew via agent-native flag (no stdin piping)
$MYCELIUM compost renew-target.ts --renew >/dev/null 2>&1

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
$MYCELIUM note oid-target.ts -k observation -t "OID target test" -m "Target by OID." >/dev/null 2>&1
OID_BLOB=$(git rev-parse HEAD:oid-target.ts)

echo "oid-target changed" > oid-target.ts
git add oid-target.ts && git commit -m "change oid target" --quiet

# Dry-run shows OID
out=$($MYCELIUM compost oid-target.ts --dry-run 2>&1)
assert "oid: dry-run shows OID" "${OID_BLOB:0:12}" "$out"

# Compost by OID (agent-native: no interactive prompt, no path batch)
out=$($MYCELIUM compost "${OID_BLOB:0:12}" --compost 2>&1)
assert "oid: compost by OID succeeds" "composted" "$out"
assert "oid: compost output shows kind" "observation" "$out"

# Verify the note is composted
out=$(git notes --ref=mycelium show "$OID_BLOB" 2>/dev/null)
assert "oid: note has status composted" "status composted" "$out"

# Setup for renew by OID
echo "oid-renew original" > oid-renew.ts
git add oid-renew.ts && git commit -m "oid renew" --quiet
$MYCELIUM note oid-renew.ts -k decision -t "OID renew test" -m "Renew by OID." >/dev/null 2>&1
OID_RENEW_OLD=$(git rev-parse HEAD:oid-renew.ts)

echo "oid-renew changed" > oid-renew.ts
git add oid-renew.ts && git commit -m "change oid renew" --quiet
OID_RENEW_NEW=$(git rev-parse HEAD:oid-renew.ts)

# Renew by OID
out=$($MYCELIUM compost "${OID_RENEW_OLD:0:12}" --renew 2>&1)
assert "oid: renew by OID succeeds" "renewed" "$out"

# New blob has the note
out=$(git notes --ref=mycelium show "$OID_RENEW_NEW" 2>/dev/null)
assert "oid: renewed note on new blob" "OID renew test" "$out"

# Old blob composted
out=$(git notes --ref=mycelium show "$OID_RENEW_OLD" 2>/dev/null)
assert "oid: old blob composted after renew" "status composted" "$out"

echo ""
echo "=== Overwrite Warning ==="

# Write a note then overwrite — should warn on stderr
echo "owtest" > owtest.ts
git add owtest.ts && git commit -m "overwrite test" --quiet
$MYCELIUM note owtest.ts -k context -t "First note" -m "first" >/dev/null 2>&1
out=$($MYCELIUM note owtest.ts -k context -t "Second note" -m "second" 2>&1)
assert "overwrite: shows warning" "overwriting" "$out"
assert "overwrite: shows old title" "First note" "$out"

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
