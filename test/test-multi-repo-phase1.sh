#!/usr/bin/env bash
# mycelium multi-repo Phase 1 test suite
#
# Tests same-trust-domain import/export between two repos:
#   - import: fetch foreign export ref into local import ref
#   - imported notes in context/find/kinds/doctor
#   - read-only enforcement on import refs
#   - cross-repo edge display
#   - no auto-fetch invariant
#   - isolation between repos
#
# Requires Phase 0 commands (repo-id, zone, export) to be implemented.
# Runs in temporary git repos with file:// remotes. No network calls.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MYCELIUM="$REPO_ROOT/mycelium.sh"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- test harness (same as test.sh) ---

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

# --- helpers ---

# Create a fresh repo, init repo-id, commit config, return path.
# Caller must cd into the returned path.
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
  # Init repo-id and commit it
  cd "$dir"
  $MYCELIUM repo-id init >/dev/null 2>&1
  mkdir -p .mycelium
  git add .mycelium/
  git commit -q --no-verify -m "add mycelium repo-id"
  echo "$dir"
}

# Set up two repos. REPO_A exports, REPO_B imports.
# REPO_B has REPO_A as remote "source" via file:// URL.
# Writes notes in REPO_A, exports them, then returns.
# After calling: cd "$REPO_B" to test import.
setup_two_repos() {
  REPO_A=$(make_repo)
  REPO_A_ID=$(cat "$REPO_A/.mycelium/repo-id")

  # Write notes in REPO_A
  cd "$REPO_A"
  $MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "Chose TS for type safety." >/dev/null 2>&1
  $MYCELIUM note -f README.md -k summary -t "Project overview" -m "What this project does." >/dev/null 2>&1
  $MYCELIUM note -f . -k constraint -t "No side effects in lib" -m "Pure functions only." >/dev/null 2>&1
  $MYCELIUM note -f HEAD -k context -t "Session note" -m "Initial setup." >/dev/null 2>&1

  # Export to internal
  BLOB_MAIN_A=$(git rev-parse HEAD:src/main.ts)
  BLOB_README_A=$(git rev-parse HEAD:README.md)
  ROOT_TREE_A=$(git rev-parse HEAD^{tree})
  COMMIT_A=$(git rev-parse HEAD)
  $MYCELIUM export src/main.ts --audience internal >/dev/null 2>&1
  $MYCELIUM export README.md --audience internal >/dev/null 2>&1
  $MYCELIUM export . --audience internal >/dev/null 2>&1
  $MYCELIUM export HEAD --audience internal >/dev/null 2>&1

  # Create REPO_B with REPO_A as remote
  REPO_B=$(make_repo)
  REPO_B_ID=$(cat "$REPO_B/.mycelium/repo-id")
  cd "$REPO_B"
  git remote add source "file://$REPO_A"
}


# =====================================================================
echo ""
echo "=== Phase 1: Same-Trust-Domain Import/Export ==="
echo ""

# =====================================================================
echo "=== import command ==="

setup_two_repos
cd "$REPO_B"

# Import from source (default: --audience internal)
out=$($MYCELIUM import source 2>&1) || true
assert "import: succeeds" "$REPO_A_ID" "$out"

# Import ref was created
IMPORT_REFS=$(git for-each-ref --format='%(refname)' "refs/notes/mycelium--import--*" 2>/dev/null || echo "")
assert "import: ref created" "mycelium--import--" "$IMPORT_REFS"

# Import ref contains notes from REPO_A's export
IMPORT_REF_SHORT=$(echo "$IMPORT_REFS" | head -1 | sed 's|refs/notes/||')
IMPORT_NOTES=$(git notes --ref="$IMPORT_REF_SHORT" list 2>/dev/null || echo "")
if [[ -n "$IMPORT_NOTES" ]]; then
  IMPORT_COUNT=$(echo "$IMPORT_NOTES" | wc -l)
  echo "  ✓ import: notes fetched ($IMPORT_COUNT notes)"
  PASS=$((PASS + 1))
else
  echo "  ✗ import: no notes in import ref"
  FAIL=$((FAIL + 1))
fi

# Imported note content is intact
FIRST_OBJ=$(echo "$IMPORT_NOTES" | head -1 | awk '{print $2}')
FIRST_NOTE=$(git notes --ref="$IMPORT_REF_SHORT" show "$FIRST_OBJ" 2>/dev/null || echo "")
assert "import: note content intact" "kind" "$FIRST_NOTE"

# Import has exported-from edge (inherited from export)
assert "import: exported-from edge present" "exported-from" "$FIRST_NOTE"

# Import did NOT fetch working ref from source
WORKING_FETCHED=$(git notes --ref=mycelium list 2>/dev/null | wc -l || echo "0")
# REPO_B should have 0 notes in its working ref (we only wrote repo-id, no notes)
if [[ "$WORKING_FETCHED" -eq 0 ]]; then
  echo "  ✓ import: working ref not fetched from source"
  PASS=$((PASS + 1))
else
  echo "  ✗ import: working ref was contaminated ($WORKING_FETCHED notes)"
  FAIL=$((FAIL + 1))
fi

# Import did NOT fetch slot refs from source
SLOT_FETCHED=$(git for-each-ref --format='%(refname)' "refs/notes/mycelium--slot--*" 2>/dev/null | wc -l || echo "0")
if [[ "$SLOT_FETCHED" -eq 0 ]]; then
  echo "  ✓ import: slot refs not fetched from source"
  PASS=$((PASS + 1))
else
  echo "  ✗ import: slot refs were fetched ($SLOT_FETCHED refs)"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== import --as alias ==="

setup_two_repos
cd "$REPO_B"

# Import with human-friendly alias
out=$($MYCELIUM import source --as infra-lib 2>&1) || true
assert "import --as: succeeds" "infra-lib" "$out"

# Ref uses alias, not repo-id
ALIAS_REF=$(git for-each-ref --format='%(refname)' "refs/notes/mycelium--import--infra-lib" 2>/dev/null || echo "")
assert "import --as: ref uses alias" "infra-lib" "$ALIAS_REF"

# Notes are readable via alias
ALIAS_NOTES=$(git notes --ref=mycelium--import--infra-lib list 2>/dev/null || echo "")
if [[ -n "$ALIAS_NOTES" ]]; then
  echo "  ✓ import --as: notes accessible via alias"
  PASS=$((PASS + 1))
else
  echo "  ✗ import --as: no notes under alias ref"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== import --refresh ==="

setup_two_repos
cd "$REPO_B"

# First import
$MYCELIUM import source --as lib-a >/dev/null 2>&1 || true
FIRST_COUNT=$(git notes --ref=mycelium--import--lib-a list 2>/dev/null | wc -l)

# Add another note in REPO_A and export it
cd "$REPO_A"
echo "new file" > src/new.ts
git add src/new.ts && git commit -q --no-verify -m "add new file"
$MYCELIUM note -f src/new.ts -k warning -t "Fragile" -m "Handle with care." >/dev/null 2>&1
$MYCELIUM export src/new.ts --audience internal >/dev/null 2>&1

# Refresh import in REPO_B
cd "$REPO_B"
out=$($MYCELIUM import source --as lib-a --refresh 2>&1) || true
REFRESH_COUNT=$(git notes --ref=mycelium--import--lib-a list 2>/dev/null | wc -l)

if [[ "$REFRESH_COUNT" -gt "$FIRST_COUNT" ]]; then
  echo "  ✓ import --refresh: picks up new notes ($FIRST_COUNT → $REFRESH_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  ✗ import --refresh: no new notes ($FIRST_COUNT → $REFRESH_COUNT)"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== import error cases ==="

setup_two_repos
cd "$REPO_B"

# Import from remote with no export ref
git remote add empty-remote "file://$REPO_B"  # REPO_B has no exports
IMPORT_RC=0
out=$($MYCELIUM import empty-remote --as empty 2>&1) || IMPORT_RC=$?
if [[ "$IMPORT_RC" -ne 0 ]]; then
  echo "  ✓ import: no export ref produces error"
  PASS=$((PASS + 1))
else
  echo "  ✗ import: should fail when remote has no export ref"
  FAIL=$((FAIL + 1))
fi

# Import without --as from repo with no exported-from edges should fail clearly
# (We test with a well-formed export, so this path is the fallback)


# =====================================================================
echo ""
echo "=== imported notes in context ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as source-repo >/dev/null 2>&1 || true

# Write a local note on a file that also has an imported note
# REPO_B has its own src/main.ts (from make_repo), different blob OID
$MYCELIUM note -f src/main.ts -k observation -t "Local observation" -m "My own note." >/dev/null 2>&1

# Context should show both local and imported notes
out=$($MYCELIUM context src/main.ts 2>&1)
assert "context: shows local note" "Local observation" "$out"

# Imported notes may not match local blob OID (different repos, different content).
# But if REPO_A exported a root-tree note, it should show via import scanning.
out=$($MYCELIUM context . 2>&1)
# The root tree note "No side effects in lib" was exported from REPO_A
# It should appear with an [import:source-repo] label if context scans imports
assert "context: shows imported root note" "import" "$out"
assert "context: import label present" "source-repo" "$out"


# =====================================================================
echo ""
echo "=== imported notes in find ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as find-test >/dev/null 2>&1 || true

# find should discover imported notes
out=$($MYCELIUM find decision 2>&1)
assert "find: discovers imported decisions" "Use TypeScript" "$out"
assert "find: labels imported notes" "import" "$out"

out=$($MYCELIUM find constraint 2>&1)
assert "find: discovers imported constraints" "No side effects" "$out"

# find for kind that only exists locally
$MYCELIUM note -f README.md -k observation -t "Local only" -m "Not imported." >/dev/null 2>&1
out=$($MYCELIUM find observation 2>&1)
assert "find: local-only kind works" "Local only" "$out"


# =====================================================================
echo ""
echo "=== imported notes in kinds ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as kinds-test >/dev/null 2>&1 || true

out=$($MYCELIUM kinds 2>&1)
assert "kinds: includes imported kinds" "decision" "$out"
assert "kinds: includes imported summary" "summary" "$out"


# =====================================================================
echo ""
echo "=== imported notes in doctor ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as doctor-test >/dev/null 2>&1 || true

out=$($MYCELIUM doctor 2>&1)
# Doctor should report imports separately
assert "doctor: reports imports" "import" "$out"
assert "doctor: reports import name" "doctor-test" "$out"


# =====================================================================
echo ""
echo "=== read-only enforcement ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as readonly-test >/dev/null 2>&1 || true

# Get an imported note's OID for testing
IMPORT_REF="mycelium--import--readonly-test"
IMPORTED_OBJ=$(git notes --ref="$IMPORT_REF" list 2>/dev/null | head -1 | awk '{print $2}')

# note refuses to write to import ref via MYCELIUM_REF
WRITE_RC=0
out=$(MYCELIUM_REF="$IMPORT_REF" $MYCELIUM note -f HEAD -k observation -m "Should fail" 2>&1) || WRITE_RC=$?
if [[ "$WRITE_RC" -ne 0 ]]; then
  echo "  ✓ read-only: note write rejected"
  PASS=$((PASS + 1))
else
  echo "  ✗ read-only: note write should have been rejected"
  FAIL=$((FAIL + 1))
fi

# read works on imported notes
out=$($MYCELIUM read "$IMPORTED_OBJ" 2>&1) || true
# The note content should be readable (even if it shows "no note" on the local ref,
# follow should resolve it from the import ref — this depends on implementation)
# For now, direct ref reading should work:
DIRECT_READ=$(git notes --ref="$IMPORT_REF" show "$IMPORTED_OBJ" 2>/dev/null || echo "")
assert "read-only: direct git read works" "kind" "$DIRECT_READ"

# compost refuses on imported notes
COMPOST_RC=0
out=$($MYCELIUM compost "$IMPORTED_OBJ" --compost 2>&1) || COMPOST_RC=$?
# Should either fail or skip — imported notes are not compostable
if echo "$out" | grep -qi "import\|read.only\|error"; then
  echo "  ✓ read-only: compost rejected on import"
  PASS=$((PASS + 1))
elif [[ "$COMPOST_RC" -ne 0 ]]; then
  echo "  ✓ read-only: compost failed on import (exit $COMPOST_RC)"
  PASS=$((PASS + 1))
else
  echo "  ✗ read-only: compost should have been rejected on imported note"
  FAIL=$((FAIL + 1))
fi

# branch use rejects import namespace
BRANCH_RC=0
out=$($MYCELIUM branch use "import--readonly-test" 2>&1) || BRANCH_RC=$?
if [[ "$BRANCH_RC" -ne 0 ]]; then
  echo "  ✓ read-only: branch use import-- rejected"
  PASS=$((PASS + 1))
else
  echo "  ✗ read-only: branch use import-- should have been rejected"
  FAIL=$((FAIL + 1))
fi

# branch use rejects export namespace
BRANCH_RC2=0
out=$($MYCELIUM branch use "export--public" 2>&1) || BRANCH_RC2=$?
if [[ "$BRANCH_RC2" -ne 0 ]]; then
  echo "  ✓ read-only: branch use export-- rejected"
  PASS=$((PASS + 1))
else
  echo "  ✗ read-only: branch use export-- should have been rejected"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== no auto-fetch ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as no-fetch-test >/dev/null 2>&1 || true

# Add a new note in REPO_A and export it
cd "$REPO_A"
echo "another" > src/another.ts
git add src/another.ts && git commit -q --no-verify -m "add another"
$MYCELIUM note -f src/another.ts -k warning -t "New warning" -m "Added after import." >/dev/null 2>&1
$MYCELIUM export src/another.ts --audience internal >/dev/null 2>&1

# Back in REPO_B — context/find/follow should NOT see the new note (no auto-fetch)
cd "$REPO_B"
out=$($MYCELIUM find warning 2>&1) || true
assert_not "no-fetch: context doesn't auto-fetch" "New warning" "$out"

out=$($MYCELIUM context src/another.ts 2>&1) || true
assert_not "no-fetch: find doesn't auto-fetch" "New warning" "$out"

# After explicit refresh, the note appears
$MYCELIUM import source --as no-fetch-test --refresh >/dev/null 2>&1 || true
out=$($MYCELIUM find warning 2>&1) || true
assert "no-fetch: refresh makes new note visible" "New warning" "$out"


# =====================================================================
echo ""
echo "=== isolation ==="

setup_two_repos

# Notes written in REPO_B should not appear in REPO_A
cd "$REPO_B"
$MYCELIUM import source --as iso-test >/dev/null 2>&1 || true
$MYCELIUM note -f README.md -k observation -t "REPO_B only" -m "Local to B." >/dev/null 2>&1

cd "$REPO_A"
out=$($MYCELIUM find observation 2>&1)
assert_not "isolation: REPO_B notes not in REPO_A" "REPO_B only" "$out"

# Notes in REPO_A's working ref do NOT appear in REPO_B's import
cd "$REPO_A"
$MYCELIUM note -f src/main.ts -k warning -t "Working only" -m "Not exported." >/dev/null 2>&1
# This note was NOT exported — it should not appear in REPO_B
cd "$REPO_B"
$MYCELIUM import source --as iso-test --refresh >/dev/null 2>&1 || true
out=$($MYCELIUM find warning 2>&1) || true
assert_not "isolation: unexported notes not imported" "Working only" "$out"

# Deleting the import ref removes all imported notes
cd "$REPO_B"
git update-ref -d "refs/notes/mycelium--import--iso-test" 2>/dev/null || true
out=$($MYCELIUM find decision 2>&1) || true
assert_not "isolation: deleted import ref removes notes" "Use TypeScript" "$out"

# Two imports from different repos coexist
setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as first-lib >/dev/null 2>&1 || true

# Create a third repo
REPO_C=$(make_repo)
cd "$REPO_C"
$MYCELIUM note -f README.md -k value -t "REPO_C value" -m "From third repo." >/dev/null 2>&1
$MYCELIUM export README.md --audience internal >/dev/null 2>&1

cd "$REPO_B"
git remote add source-c "file://$REPO_C"
$MYCELIUM import source-c --as second-lib >/dev/null 2>&1 || true

# Both imports visible
out=$($MYCELIUM find decision 2>&1) || true
assert "isolation: first import visible" "Use TypeScript" "$out"
out=$($MYCELIUM find value 2>&1) || true
assert "isolation: second import visible" "REPO_C value" "$out"

# Import refs are separate
IMPORT_COUNT=$(git for-each-ref --format='%(refname)' "refs/notes/mycelium--import--*" 2>/dev/null | wc -l)
if [[ "$IMPORT_COUNT" -ge 2 ]]; then
  echo "  ✓ isolation: two import refs coexist ($IMPORT_COUNT refs)"
  PASS=$((PASS + 1))
else
  echo "  ✗ isolation: expected 2+ import refs, got $IMPORT_COUNT"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== import freshness ==="

setup_two_repos
cd "$REPO_B"
$MYCELIUM import source --as fresh-test >/dev/null 2>&1 || true

# Doctor should report freshness
out=$($MYCELIUM doctor 2>&1)
assert "freshness: doctor shows import" "fresh-test" "$out"

# The import ref tip should have a recent commit date (wrapper commit)
IMPORT_DATE=$(git log -1 --format=%ci "refs/notes/mycelium--import--fresh-test" 2>/dev/null || echo "")
if [[ -n "$IMPORT_DATE" ]]; then
  echo "  ✓ freshness: import ref has commit date ($IMPORT_DATE)"
  PASS=$((PASS + 1))
else
  echo "  ✗ freshness: no commit date on import ref"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
