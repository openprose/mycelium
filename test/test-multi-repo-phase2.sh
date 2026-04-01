#!/usr/bin/env bash
# mycelium multi-repo Phase 2 test suite
#
# Tests improvements to the multi-repo surface:
#   - batch export: export --all, --kind filter
#   - list-imports: user-facing command to list imported repos
#   - foreign blob labels: imported objects show [foreign] not ??:
#
# Builds on Phase 1 infrastructure (import/export working).
# Runs in temporary git repos with file:// remotes. No network calls.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MYCELIUM="$REPO_ROOT/mycelium.sh"
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

assert_exit() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "  ✓ $name (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# --- helpers ---

make_repo() {
  local dir
  dir=$(mktemp -d "$TMPDIR/repo.XXXXXX")
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test"
  git -C "$dir" config user.name "test"
  mkdir -p "$dir/src"
  echo "module code" > "$dir/src/main.ts"
  echo "# readme" > "$dir/README.md"
  git -C "$dir" add .
  git -C "$dir" commit -q --no-verify -m "initial commit"
  cd "$dir"
  $MYCELIUM repo-id init >/dev/null 2>&1
  mkdir -p .mycelium
  git add .mycelium/
  git commit -q --no-verify -m "add mycelium repo-id"
  echo "$dir"
}

setup_two_repos() {
  REPO_A=$(make_repo)
  REPO_A_ID=$(cat "$REPO_A/.mycelium/repo-id")

  cd "$REPO_A"
  # Write several notes of different kinds
  $MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "Chose TS for type safety." >/dev/null 2>&1
  $MYCELIUM note -f README.md -k decision -t "MIT license" -m "Open source from day one." >/dev/null 2>&1
  $MYCELIUM note -f . -k constraint -t "No side effects" -m "Pure functions only." >/dev/null 2>&1
  $MYCELIUM note -f HEAD -k context -t "Session note" -m "Initial setup." >/dev/null 2>&1
  $MYCELIUM note -f src/main.ts -k warning -t "Performance concern" -m "Hot path needs optimization." --slot perf >/dev/null 2>&1

  # Export some individually for comparison
  BLOB_MAIN_A=$(git rev-parse HEAD:src/main.ts)
  BLOB_README_A=$(git rev-parse HEAD:README.md)
  ROOT_TREE_A=$(git rev-parse HEAD^{tree})
  COMMIT_A=$(git rev-parse HEAD)

  # Create REPO_B with REPO_A as remote
  REPO_B=$(make_repo)
  cd "$REPO_B"
  git remote add source "file://$REPO_A"
}

# =======================================================================
echo "=== Batch Export ==="
# =======================================================================

echo "--- export --all --audience internal ---"
REPO_A=$(make_repo)
cd "$REPO_A"
$MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "TS for safety." >/dev/null 2>&1
$MYCELIUM note -f README.md -k decision -t "MIT license" -m "Open source." >/dev/null 2>&1
$MYCELIUM note -f . -k constraint -t "No side effects" -m "Pure functions." >/dev/null 2>&1
$MYCELIUM note -f HEAD -k context -t "Session note" -m "Setup." >/dev/null 2>&1

OUT=$($MYCELIUM export --all --audience internal 2>&1)
assert "export --all: exports all notes" "4 note(s) exported" "$OUT"

# Verify export ref has all 4
EXPORT_COUNT=$(git notes --ref=mycelium--export--internal list 2>/dev/null | wc -l)
assert "export --all: 4 notes in export ref" "4" "$EXPORT_COUNT"

echo ""
echo "--- export --all --kind decision ---"
# Fresh repo so counts are clean
REPO_C=$(make_repo)
cd "$REPO_C"
$MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "TS for safety." >/dev/null 2>&1
$MYCELIUM note -f README.md -k decision -t "MIT license" -m "Open source." >/dev/null 2>&1
$MYCELIUM note -f . -k constraint -t "No side effects" -m "Pure functions." >/dev/null 2>&1
$MYCELIUM note -f HEAD -k context -t "Session note" -m "Setup." >/dev/null 2>&1

OUT=$($MYCELIUM export --all --kind decision --audience internal 2>&1)
assert "export --all --kind: only exports decisions" "2 note(s) exported" "$OUT"

EXPORT_COUNT=$(git notes --ref=mycelium--export--internal list 2>/dev/null | wc -l)
assert "export --all --kind: 2 notes in export ref" "2" "$EXPORT_COUNT"

echo ""
echo "--- export --all --kind with slot ---"
REPO_D=$(make_repo)
cd "$REPO_D"
$MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "TS for safety." >/dev/null 2>&1
$MYCELIUM note -f src/main.ts -k warning -t "Perf concern" -m "Hot path." --slot perf >/dev/null 2>&1
$MYCELIUM note -f README.md -k warning -t "Stale docs" -m "Needs update." --slot perf >/dev/null 2>&1

OUT=$($MYCELIUM export --all --kind warning --slot perf --audience internal 2>&1)
assert "export --all --kind --slot: exports from slot" "2 note(s) exported" "$OUT"

EXPORT_COUNT=$(git notes --ref=mycelium--export--internal list 2>/dev/null | wc -l)
assert "export --all --kind --slot: 2 in export ref" "2" "$EXPORT_COUNT"

echo ""
echo "--- export --all with no notes ---"
REPO_E=$(make_repo)
cd "$REPO_E"
OUT=$($MYCELIUM export --all --audience internal 2>&1)
RC=$?
assert "export --all empty: reports 0" "0 note(s) exported" "$OUT"

echo ""
echo "--- export --all rejects target + --all ---"
cd "$REPO_C"
OUT=$($MYCELIUM export --all src/main.ts --audience internal 2>&1 || true)
assert "export --all + target: error" "cannot be combined" "$OUT"

echo ""
echo "--- export --all adds exported-from edge ---"
cd "$REPO_C"
# Pick one exported note and verify it has the edge
FIRST_OID=$(git notes --ref=mycelium--export--internal list 2>/dev/null | head -1 | awk '{print $2}')
EXPORTED_CONTENT=$(git notes --ref=mycelium--export--internal show "$FIRST_OID" 2>/dev/null)
assert "export --all: has exported-from edge" "edge exported-from repo:" "$EXPORTED_CONTENT"

echo ""
echo "--- export --all skips already-exported (idempotent) ---"
cd "$REPO_C"
OUT=$($MYCELIUM export --all --kind decision --audience internal 2>&1)
assert "export --all idempotent: still 2" "2 note(s) exported" "$OUT"
EXPORT_COUNT=$(git notes --ref=mycelium--export--internal list 2>/dev/null | wc -l)
assert "export --all idempotent: count unchanged" "2" "$EXPORT_COUNT"

echo ""
echo "--- export --all respects public policy ---"
REPO_F=$(make_repo)
cd "$REPO_F"
mkdir -p .mycelium
cat > .mycelium/export-policy <<'EOF'
allowed_kinds = decision, context
deny_patterns = SECRET, CONFIDENTIAL
EOF
git add .mycelium/export-policy
git commit -q --no-verify -m "add export policy"

$MYCELIUM note -f src/main.ts -k decision -t "Public decision" -m "This is fine." >/dev/null 2>&1
$MYCELIUM note -f README.md -k warning -t "Internal warning" -m "Not for public." >/dev/null 2>&1
$MYCELIUM note -f . -k context -t "Public context" -m "Background info." >/dev/null 2>&1

OUT=$($MYCELIUM export --all --audience public 2>&1)
assert "export --all public: respects allowed_kinds" "2 note(s) exported" "$OUT"

EXPORT_COUNT=$(git notes --ref=mycelium--export--public list 2>/dev/null | wc -l)
assert "export --all public: only allowed kinds" "2" "$EXPORT_COUNT"


# =======================================================================
echo ""
echo "=== List Imports ==="
# =======================================================================

echo "--- list-imports with no imports ---"
REPO_G=$(make_repo)
cd "$REPO_G"
OUT=$($MYCELIUM list-imports 2>&1)
assert "list-imports empty: reports none" "No imports" "$OUT"

echo ""
echo "--- list-imports with imports ---"
setup_two_repos
cd "$REPO_A"
$MYCELIUM export --all --audience internal >/dev/null 2>&1

cd "$REPO_B"
$MYCELIUM import source --as upstream >/dev/null 2>&1

OUT=$($MYCELIUM list-imports 2>&1)
assert "list-imports: shows name" "upstream" "$OUT"
assert "list-imports: shows note count" "note(s)" "$OUT"
assert "list-imports: shows remote" "source" "$OUT"

echo ""
echo "--- list-imports with multiple imports ---"
# Create a third repo and import from it too
REPO_H=$(make_repo)
cd "$REPO_H"
$MYCELIUM note -f HEAD -k context -t "Third repo" -m "Another source." >/dev/null 2>&1
$MYCELIUM export --all --audience internal >/dev/null 2>&1

cd "$REPO_B"
git remote add third "file://$REPO_H"
$MYCELIUM import third --as thirdparty >/dev/null 2>&1

OUT=$($MYCELIUM list-imports 2>&1)
assert "list-imports multiple: shows upstream" "upstream" "$OUT"
assert "list-imports multiple: shows thirdparty" "thirdparty" "$OUT"


# =======================================================================
echo ""
echo "=== Foreign Blob Labels ==="
# =======================================================================

echo "--- find shows foreign labels for imported objects ---"
cd "$REPO_B"
OUT=$($MYCELIUM find decision 2>&1)
# Imported blobs from REPO_A are fetched locally — should show blob:/commit:/tree: not ??:
assert_not "find: no ??: for foreign objects" "??:" "$OUT"
# Should show something identifying them as foreign or imported
assert "find: shows import label" "[import:" "$OUT"

echo ""
echo "--- doctor shows foreign imports cleanly ---"
cd "$REPO_B"
OUT=$($MYCELIUM doctor 2>&1)
assert_not "doctor: no ??: in output" "??:" "$OUT"
assert_not "doctor: no ext: in output" "ext:" "$OUT"
assert "doctor: shows import line" "import " "$OUT"


# =======================================================================
echo ""
echo "=== Summary ==="
# =======================================================================

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]] || exit 1
