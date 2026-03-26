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

# read nonexistent note
out=$($MYCELIUM read "$BLOB_RETRY" 2>&1 || true)
# The blob has a note, try a fresh blob
echo "new file" > newfile.txt
git add newfile.txt
git commit -q --no-verify -m "add newfile"
out=$($MYCELIUM read newfile.txt 2>&1)
assert "read missing note" "(no mycelium note)" "$out"

echo ""
echo "=== Context ==="

# Context walks blob → tree → commit
$MYCELIUM note -k context -m "Commit context for context test" >/dev/null
out=$($MYCELIUM context src/auth/retry.ts)
assert "context shows blob note" "[blob]" "$out"
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
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
