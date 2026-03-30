#!/usr/bin/env bash
# mycelium multi-repo Phase 0 test suite
#
# Tests the ref architecture for cross-repo support within a single repo:
#   - repo-id: durable repository identity
#   - zone: confidentiality level declaration
#   - export: curated note publication to export refs
#   - sync-init --export-only: refspec configuration
#   - reference-transaction hook: export ref gating
#   - export-policy: checked-in policy enforcement
#
# Runs in temporary git repos. No network calls.
# These tests define the INTENDED interface — they will fail until the
# commands are implemented. That's by design: tests are the spec.
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

assert_exit() {
  local name="$1" expected_code="$2"
  shift 2
  local actual_code=0
  "$@" >/dev/null 2>&1 || actual_code=$?
  if [[ "$actual_code" -eq "$expected_code" ]]; then
    echo "  ✓ $name (exit $actual_code)"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected exit $expected_code, got $actual_code)"
    FAIL=$((FAIL + 1))
  fi
}

# --- helpers ---

# Create a fresh git repo in a temp directory and cd into it
setup_repo() {
  local dir
  dir=$(mktemp -d "$TMPDIR/repo.XXXXXX")
  cd "$dir"
  git init -q
  git config user.email "test@test"
  git config user.name "test"
  mkdir -p src
  echo "module code" > src/main.ts
  echo "# readme" > README.md
  git add .
  git commit -q --no-verify -m "initial commit"
  echo "$dir"
}

# Install the reference-transaction hook in the correct location.
# Respects core.hooksPath if set, falls back to .git/hooks/.
install_ref_tx_hook() {
  local hook_dir
  hook_dir=$(git config --get core.hooksPath 2>/dev/null || echo "$(git rev-parse --git-dir)/hooks")
  mkdir -p "$hook_dir"
  cp "$REPO_ROOT/hooks/reference-transaction" "$hook_dir/reference-transaction" 2>/dev/null \
    || echo "# reference-transaction hook not yet implemented" > "$hook_dir/reference-transaction"
  chmod +x "$hook_dir/reference-transaction"
}


# =====================================================================
echo ""
echo "=== Phase 0: Ref Architecture ==="
echo ""

# =====================================================================
echo "=== repo-id ==="

REPO_A=$(setup_repo)
cd "$REPO_A"

# repo-id init creates the file
out=$($MYCELIUM repo-id init 2>&1) || true
assert "repo-id: init succeeds" "" "$out"

if [[ -f .mycelium/repo-id ]]; then
  echo "  ✓ repo-id: file created"
  PASS=$((PASS + 1))
else
  echo "  ✗ repo-id: file not created at .mycelium/repo-id"
  FAIL=$((FAIL + 1))
fi

# repo-id is non-empty
REPO_ID=$(cat .mycelium/repo-id 2>/dev/null || echo "")
if [[ -n "$REPO_ID" ]]; then
  echo "  ✓ repo-id: non-empty ($REPO_ID)"
  PASS=$((PASS + 1))
else
  echo "  ✗ repo-id: empty or missing"
  FAIL=$((FAIL + 1))
fi

# repo-id is valid hex (at least 8 chars of hex)
if echo "$REPO_ID" | grep -qE '^[0-9a-f]{8,}$'; then
  echo "  ✓ repo-id: valid hex format"
  PASS=$((PASS + 1))
else
  echo "  ✗ repo-id: not valid hex (got: $REPO_ID)"
  FAIL=$((FAIL + 1))
fi

# repo-id is stable (second call returns same value)
$MYCELIUM repo-id init >/dev/null 2>&1 || true
REPO_ID_2=$(cat .mycelium/repo-id 2>/dev/null || echo "")
if [[ "$REPO_ID" == "$REPO_ID_2" ]]; then
  echo "  ✓ repo-id: stable across invocations"
  PASS=$((PASS + 1))
else
  echo "  ✗ repo-id: changed on second init ($REPO_ID vs $REPO_ID_2)"
  FAIL=$((FAIL + 1))
fi

# repo-id show prints the id
out=$($MYCELIUM repo-id 2>&1) || true
assert "repo-id: show prints id" "$REPO_ID" "$out"

# Two different repos get different IDs
REPO_B=$(setup_repo)
cd "$REPO_B"
$MYCELIUM repo-id init >/dev/null 2>&1 || true
REPO_ID_B=$(cat .mycelium/repo-id 2>/dev/null || echo "")
if [[ "$REPO_ID" != "$REPO_ID_B" && -n "$REPO_ID_B" ]]; then
  echo "  ✓ repo-id: unique across repos"
  PASS=$((PASS + 1))
else
  echo "  ✗ repo-id: not unique ($REPO_ID vs $REPO_ID_B)"
  FAIL=$((FAIL + 1))
fi


# =====================================================================
echo ""
echo "=== zone ==="

cd "$REPO_A"

# zone init with default level
out=$($MYCELIUM zone init 2>&1) || true
if [[ -f .mycelium/zone ]]; then
  echo "  ✓ zone: file created"
  PASS=$((PASS + 1))
else
  echo "  ✗ zone: file not created at .mycelium/zone"
  FAIL=$((FAIL + 1))
fi

# Default is a safe high value (80 = private)
ZONE=$(cat .mycelium/zone 2>/dev/null || echo "")
if [[ -n "$ZONE" ]] && [[ "$ZONE" -ge 60 ]] 2>/dev/null; then
  echo "  ✓ zone: default is high ($ZONE)"
  PASS=$((PASS + 1))
else
  echo "  ✗ zone: default too low or not numeric (got: $ZONE)"
  FAIL=$((FAIL + 1))
fi

# zone file is a single integer
ZONE_LINES=$( [[ -f .mycelium/zone ]] && wc -l < .mycelium/zone || echo "999")
if [[ "$ZONE_LINES" -le 1 ]] && echo "$ZONE" | grep -qE '^[0-9]+$'; then
  echo "  ✓ zone: single integer"
  PASS=$((PASS + 1))
else
  echo "  ✗ zone: not a single integer (lines: $ZONE_LINES, content: $ZONE)"
  FAIL=$((FAIL + 1))
fi

# zone init with explicit level
$MYCELIUM zone init 40 >/dev/null 2>&1 || true
ZONE_40=$(cat .mycelium/zone 2>/dev/null || echo "")
if [[ "$ZONE_40" == "40" ]]; then
  echo "  ✓ zone: explicit level accepted (40)"
  PASS=$((PASS + 1))
else
  echo "  ✗ zone: explicit level not applied (got: $ZONE_40)"
  FAIL=$((FAIL + 1))
fi

# zone show prints the level
out=$($MYCELIUM zone 2>&1) || true
assert "zone: show prints level" "40" "$out"

# zone is idempotent
$MYCELIUM zone init 40 >/dev/null 2>&1 || true
ZONE_AGAIN=$(cat .mycelium/zone 2>/dev/null || echo "")
if [[ "$ZONE_AGAIN" == "40" ]]; then
  echo "  ✓ zone: idempotent"
  PASS=$((PASS + 1))
else
  echo "  ✗ zone: not idempotent (got: $ZONE_AGAIN)"
  FAIL=$((FAIL + 1))
fi

# Reset to default for remaining tests
$MYCELIUM zone init 80 >/dev/null 2>&1 || true


# =====================================================================
echo ""
echo "=== export ==="

cd "$REPO_A"

# Ensure repo-id exists (export needs it)
$MYCELIUM repo-id init >/dev/null 2>&1 || true
REPO_ID=$(cat .mycelium/repo-id 2>/dev/null || echo "test-repo-id")
git add .mycelium/ 2>/dev/null && git commit -q --no-verify -m "add mycelium config" 2>/dev/null || true

# Create a note to export
$MYCELIUM note -f src/main.ts -k decision -t "Use TypeScript" -m "Chose TS for type safety." >/dev/null 2>&1
BLOB_MAIN=$(git rev-parse HEAD:src/main.ts)

# Missing --audience is an error (export must be deliberate)
out=$($MYCELIUM export "$BLOB_MAIN" 2>&1) || true
assert "export: --audience required" "audience" "$out"

# Export to internal audience
out=$($MYCELIUM export "$BLOB_MAIN" --audience internal 2>&1) || true
assert "export: succeeds" "$BLOB_MAIN" "$out"

# Verify the note exists on the export ref
EXPORT_NOTE=$(git notes --ref=mycelium--export--internal show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: note on internal export ref" "kind decision" "$EXPORT_NOTE"
assert "export: title preserved" "Use TypeScript" "$EXPORT_NOTE"
assert "export: body preserved" "type safety" "$EXPORT_NOTE"

# Exported note has exported-from edge
assert "export: has exported-from edge" "exported-from" "$EXPORT_NOTE"
assert "export: exported-from contains repo-id" "$REPO_ID" "$EXPORT_NOTE"

# Working ref is untouched
WORKING_NOTE=$(git notes --ref=mycelium show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: working ref untouched" "Use TypeScript" "$WORKING_NOTE"

# Export to public audience
out=$($MYCELIUM export "$BLOB_MAIN" --audience public 2>&1) || true
PUBLIC_NOTE=$(git notes --ref=mycelium--export--public show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: note on public export ref" "kind decision" "$PUBLIC_NOTE"

# Double-export is idempotent
out=$($MYCELIUM export "$BLOB_MAIN" --audience internal 2>&1) || true
EXPORT_NOTE_2=$(git notes --ref=mycelium--export--internal show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: idempotent" "Use TypeScript" "$EXPORT_NOTE_2"

# Export ref has its own commit history
EXPORT_LOG=$(git rev-parse --verify refs/notes/mycelium--export--internal &>/dev/null && git log --oneline refs/notes/mycelium--export--internal 2>/dev/null | wc -l || echo "0")
if [[ "$EXPORT_LOG" -ge 1 ]]; then
  echo "  ✓ export: ref has commit history ($EXPORT_LOG commits)"
  PASS=$((PASS + 1))
else
  echo "  ✗ export: ref has no commit history"
  FAIL=$((FAIL + 1))
fi

# Export via path target (not just OID)
$MYCELIUM note -f README.md -k summary -t "Project overview" -m "Description of the project." >/dev/null 2>&1
out=$($MYCELIUM export README.md --audience internal 2>&1) || true
BLOB_README=$(git rev-parse HEAD:README.md)

# Slot-only note is NOT exportable without --slot
$MYCELIUM note -f src/main.ts --slot review -k observation -t "Slot only" -m "Review note." >/dev/null 2>&1
# The default ref note on src/main.ts is 'Use TypeScript' (decision), not the slot note.
# Exporting without --slot should get the default ref note, not the slot note.
$MYCELIUM export src/main.ts --audience internal >/dev/null 2>&1 || true
SLOT_EXPORT_CHECK=$(git notes --ref=mycelium--export--internal show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: exports default ref, not slot" "Use TypeScript" "$SLOT_EXPORT_CHECK"
assert_not "export: slot note not in export" "Slot only" "$SLOT_EXPORT_CHECK"
README_EXPORT=$(git notes --ref=mycelium--export--internal show "$BLOB_README" 2>/dev/null || echo "")
assert "export: path target works" "Project overview" "$README_EXPORT"


# =====================================================================
echo ""
echo "=== export-policy ==="

cd "$REPO_A"

# No policy file = permissive (already tested above — exports succeeded)

# Create a restrictive policy
mkdir -p .mycelium
cat > .mycelium/export-policy << 'POLICY'
allowed_kinds = decision, constraint, warning, summary
deny_patterns = internal-*, JIRA-*, secret
forbid_imported_taint = true
POLICY
git add .mycelium/export-policy && git commit -q --no-verify -m "add export policy" 2>/dev/null || true

# Export of allowed kind succeeds
$MYCELIUM note -f src/main.ts -k constraint -t "No raw SQL" -m "Use the query builder." >/dev/null 2>&1
BLOB_MAIN=$(git rev-parse HEAD:src/main.ts)
out=$($MYCELIUM export "$BLOB_MAIN" --audience public 2>&1) || true
CONSTRAINT_EXPORT=$(git notes --ref=mycelium--export--public show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "policy: allowed kind exports" "No raw SQL" "$CONSTRAINT_EXPORT"

# Export of denied kind is rejected
echo "test observation" > obs.txt
git add obs.txt && git commit -q --no-verify -m "add obs" 2>/dev/null
$MYCELIUM note -f obs.txt -k observation -t "Noticed something" -m "Internal observation." >/dev/null 2>&1
BLOB_OBS=$(git rev-parse HEAD:obs.txt)
out=$($MYCELIUM export "$BLOB_OBS" --audience public 2>&1) || true
OBS_EXPORT=$(git notes --ref=mycelium--export--public show "$BLOB_OBS" 2>/dev/null || echo "NOT_FOUND")
# observation is not in allowed_kinds — export should fail
assert "policy: denied kind rejected" "NOT_FOUND" "$OBS_EXPORT"

# Export of note with deny_pattern in body is rejected
echo "secret-test" > secret-test.txt
git add secret-test.txt && git commit -q --no-verify -m "add secret-test" 2>/dev/null
$MYCELIUM note -f secret-test.txt -k decision -t "Safe title" -m "See JIRA-1234 for details." >/dev/null 2>&1
BLOB_SECRET=$(git rev-parse HEAD:secret-test.txt)
out=$($MYCELIUM export "$BLOB_SECRET" --audience public 2>&1) || true
SECRET_EXPORT=$(git notes --ref=mycelium--export--public show "$BLOB_SECRET" 2>/dev/null || echo "NOT_FOUND")
assert "policy: deny_pattern in body rejected" "NOT_FOUND" "$SECRET_EXPORT"

# Internal export bypasses export-policy entirely (same trust domain).
# observation is NOT in allowed_kinds, but internal doesn't check.
out=$($MYCELIUM export "$BLOB_OBS" --audience internal 2>&1) || true
OBS_INTERNAL=$(git notes --ref=mycelium--export--internal show "$BLOB_OBS" 2>/dev/null || echo "")
assert "policy: internal export is permissive" "Noticed something" "$OBS_INTERNAL"

# Export of tainted note to public is rejected when forbid_imported_taint=true
echo "tainted-file" > tainted.txt
git add tainted.txt && git commit -q --no-verify -m "add tainted" 2>/dev/null
BLOB_TAINTED=$(git rev-parse HEAD:tainted.txt)
# Write a note with a taint header (simulating agent that read imported notes)
git notes --ref=mycelium add -f -m "kind decision
title Tainted decision
taint xref:private-repo-abc123
edge applies-to blob:$BLOB_TAINTED
edge targets-path path:tainted.txt

Based on knowledge from private repo." "$BLOB_TAINTED" 2>/dev/null
out=$($MYCELIUM export "$BLOB_TAINTED" --audience public 2>&1) || true
TAINT_EXPORT=$(git notes --ref=mycelium--export--public show "$BLOB_TAINTED" 2>/dev/null || echo "NOT_FOUND")
assert "policy: tainted note rejected for public export" "NOT_FOUND" "$TAINT_EXPORT"

# Same tainted note exports to internal (taint is same-trust-domain safe)
out=$($MYCELIUM export "$BLOB_TAINTED" --audience internal 2>&1) || true
TAINT_INTERNAL=$(git notes --ref=mycelium--export--internal show "$BLOB_TAINTED" 2>/dev/null || echo "")
assert "policy: tainted note allowed for internal export" "Tainted decision" "$TAINT_INTERNAL"


# =====================================================================
echo ""
echo "=== sync-init --export-only ==="

cd "$REPO_A"
git remote add testremote https://example.com/test.git 2>/dev/null || true

# sync-init --export-only
out=$($MYCELIUM sync-init --export-only testremote 2>&1) || true
assert "sync-init export-only: reports success" "testremote" "$out"

# Check refspecs: export refs configured
FETCH_REFS=$(git config --get-all remote.testremote.fetch 2>/dev/null || echo "")
PUSH_REFS=$(git config --get-all remote.testremote.push 2>/dev/null || echo "")

assert "sync-init export-only: fetch internal export" "mycelium--export--internal" "$FETCH_REFS"
assert "sync-init export-only: push internal export" "mycelium--export--internal" "$PUSH_REFS"
assert "sync-init export-only: fetch public export" "mycelium--export--public" "$FETCH_REFS"
assert "sync-init export-only: push public export" "mycelium--export--public" "$PUSH_REFS"

# Working ref NOT configured
assert_not "sync-init export-only: no working ref fetch" "refs/notes/mycelium:" "$FETCH_REFS"
assert_not "sync-init export-only: no working ref push" "refs/notes/mycelium:" "$PUSH_REFS"

# Slots NOT configured
assert_not "sync-init export-only: no slot refs" "slot--" "$FETCH_REFS"

# Import refs NOT configured
assert_not "sync-init export-only: no import refs" "import--" "$FETCH_REFS"

# Backward compat: plain sync-init still pushes working ref
git remote remove testremote2 2>/dev/null || true
git remote add testremote2 https://example.com/test2.git 2>/dev/null || true
$MYCELIUM sync-init testremote2 >/dev/null 2>&1 || true
COMPAT_PUSH=$(git config --get-all remote.testremote2.push 2>/dev/null || echo "")
assert "sync-init compat: working ref still pushed" "refs/notes/mycelium" "$COMPAT_PUSH"


# =====================================================================
echo ""
echo "=== reference-transaction hook ==="

# Fresh repo for hook tests (clean slate)
REPO_HOOK=$(setup_repo)
cd "$REPO_HOOK"
$MYCELIUM repo-id init >/dev/null 2>&1 || true
mkdir -p .mycelium
git add .mycelium/ 2>/dev/null && git commit -q --no-verify -m "add config" 2>/dev/null || true

# Determine hook directory (respect core.hooksPath)
HOOK_DIR=$(git config --get core.hooksPath 2>/dev/null || echo "$(git rev-parse --git-dir)/hooks")
mkdir -p "$HOOK_DIR"

# Install the reference-transaction hook
# The hook should be shipped as hooks/reference-transaction in the mycelium repo.
# For now, we test the contract: the hook script at HOOK_DIR/reference-transaction
# is called by git for notes ref updates.
if [[ -f "$REPO_ROOT/hooks/reference-transaction" ]]; then
  cp "$REPO_ROOT/hooks/reference-transaction" "$HOOK_DIR/reference-transaction"
  chmod +x "$HOOK_DIR/reference-transaction"
  HOOK_INSTALLED=true
else
  HOOK_INSTALLED=false
  echo "  (reference-transaction hook not yet implemented — testing contract only)"
fi

# Create a restrictive policy for public exports
cat > .mycelium/export-policy << 'POLICY'
allowed_kinds = decision, constraint, warning, summary
deny_patterns = internal-*, JIRA-*
forbid_imported_taint = true
POLICY
git add .mycelium/ && git commit -q --no-verify -m "add policy" 2>/dev/null || true

# Write a note to working ref — should always succeed
$MYCELIUM note -f README.md -k observation -m "Working note." >/dev/null 2>&1
BLOB_README=$(git rev-parse HEAD:README.md)
WORKING=$(git notes --ref=mycelium show "$BLOB_README" 2>/dev/null || echo "")
assert "hook: working ref write allowed" "Working note" "$WORKING"

# Write a note to a slot — should always succeed
$MYCELIUM note -f README.md --slot test-hook -k observation -m "Slot note." >/dev/null 2>&1
SLOT_NOTE=$(git notes --ref=mycelium--slot--test-hook show "$BLOB_README" 2>/dev/null || echo "")
assert "hook: slot write allowed" "Slot note" "$SLOT_NOTE"

if [[ "$HOOK_INSTALLED" == "true" ]]; then

  # Valid export to public — should succeed
  git notes --ref=mycelium--export--public add -f -m "kind decision
title Valid export
edge applies-to blob:$BLOB_README
edge targets-path path:README.md

A valid decision note." "$BLOB_README" 2>/dev/null
  VALID_EXPORT=$(git notes --ref=mycelium--export--public show "$BLOB_README" 2>/dev/null || echo "")
  assert "hook: valid public export allowed" "Valid export" "$VALID_EXPORT"

  # Remove it for next test
  git notes --ref=mycelium--export--public remove "$BLOB_README" 2>/dev/null || true

  # Invalid kind via raw git notes — should be blocked
  out=$(git notes --ref=mycelium--export--public add -f -m "kind observation
title Should be blocked

Not an allowed kind for public." "$BLOB_README" 2>&1) || true
  BLOCKED=$(git notes --ref=mycelium--export--public show "$BLOB_README" 2>/dev/null || echo "BLOCKED")
  # If hook works, the note should not exist (or be "BLOCKED")
  assert "hook: denied kind blocked on public export" "BLOCKED" "$BLOCKED"

  # deny_pattern via raw git notes — should be blocked
  echo "deny-test" > deny-test.txt
  git add deny-test.txt && git commit -q --no-verify -m "deny test" 2>/dev/null
  BLOB_DENY=$(git rev-parse HEAD:deny-test.txt)
  out=$(git notes --ref=mycelium--export--public add -f -m "kind decision
title Has bad pattern

See JIRA-5678 for context." "$BLOB_DENY" 2>&1) || true
  DENY_BLOCKED=$(git notes --ref=mycelium--export--public show "$BLOB_DENY" 2>/dev/null || echo "BLOCKED")
  assert "hook: deny_pattern blocked on public export" "BLOCKED" "$DENY_BLOCKED"

  # Regular git commit should not be affected by the hook
  echo "normal change" > normal.txt
  git add normal.txt
  out=$(git commit -q --no-verify -m "normal commit" 2>&1) || true
  NORMAL_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [[ -n "$NORMAL_COMMIT" ]]; then
    echo "  ✓ hook: regular commits unaffected"
    PASS=$((PASS + 1))
  else
    echo "  ✗ hook: regular commits blocked by hook"
    FAIL=$((FAIL + 1))
  fi

  # No policy file = permissive.
  # Hook reads policy from HEAD (committed state), so this commit must land first.
  rm -f .mycelium/export-policy
  git add .mycelium/ && git commit -q --no-verify -m "remove policy" 2>/dev/null || true
  git notes --ref=mycelium--export--public add -f -m "kind observation
title Permissive mode

Anything goes without policy." "$BLOB_README" 2>/dev/null
  PERMISSIVE=$(git notes --ref=mycelium--export--public show "$BLOB_README" 2>/dev/null || echo "")
  assert "hook: no policy file = permissive" "Permissive mode" "$PERMISSIVE"

else
  echo "  (skipping hook enforcement tests — hook not yet implemented)"
fi


# =====================================================================
echo ""
echo "=== jj colocation ==="

# These tests verify jj-specific concerns for Phase 0.
# Only run if jj is available.
if command -v jj &>/dev/null; then

  REPO_JJ=$(setup_repo)
  cd "$REPO_JJ"

  # Simulate jj colocated repo
  mkdir -p .jj

  # Write notes normally (git path)
  $MYCELIUM note -f src/main.ts -k summary -t "Module overview" -m "Main entry point." >/dev/null 2>&1
  BLOB_JJ=$(git rev-parse HEAD:src/main.ts)

  # Commit note should get targets-change edge
  $MYCELIUM note -f HEAD -k context -m "jj test context." >/dev/null 2>&1
  JJ_NOTE=$($MYCELIUM read HEAD 2>&1)
  # In a real jj repo, this would have targets-change. With fake .jj, jj binary
  # may not find the repo. Test that the note is writable regardless.
  assert "jj: commit note writable in colocated repo" "jj test context" "$JJ_NOTE"

  # Verify notes refs are untouched by jj operations
  # (We tested this empirically above — documenting as a regression test)
  NOTES_BEFORE=$(git for-each-ref --format='%(refname) %(objectname)' refs/notes/ | sort)

  # Export a note
  $MYCELIUM repo-id init >/dev/null 2>&1 || true
  mkdir -p .mycelium
  git add .mycelium/ 2>/dev/null && git commit -q --no-verify -m "config" 2>/dev/null || true
  $MYCELIUM export "$BLOB_JJ" --audience internal >/dev/null 2>&1 || true

  # Verify export ref was created (by git, not jj)
  EXPORT_EXISTS=$(git notes --ref=mycelium--export--internal show "$BLOB_JJ" 2>/dev/null || echo "")
  assert "jj: export works in colocated repo" "Module overview" "$EXPORT_EXISTS"

  # Historical file notes are now a workflow script that leans on git history
  echo "updated module" > src/main.ts
  git add src/main.ts && git commit -q --no-verify -m "update module" 2>/dev/null
  out=$(MYCELIUM_REF=mycelium "$REPO_ROOT/scripts/path-history.sh" src/main.ts 2>&1)
  assert "jj: path note discoverable via history workflow" "Module overview" "$out"
  assert "jj: history workflow labels results" "[history]" "$out"

  rm -rf .jj

else
  echo "  (skipping jj tests — jj not available)"
fi


# =====================================================================
echo ""
echo "=== export edge cases ==="

REPO_EDGE=$(setup_repo)
cd "$REPO_EDGE"
$MYCELIUM repo-id init >/dev/null 2>&1 || true
mkdir -p .mycelium
git add .mycelium/ 2>/dev/null && git commit -q --no-verify -m "config" 2>/dev/null || true

# Export of nonexistent note fails clearly
BLOB_README=$(git rev-parse HEAD:README.md)
EXPORT_RC=0
out=$($MYCELIUM export "$BLOB_README" --audience internal 2>&1) || EXPORT_RC=$?
EDGE_EXPORT=$(git notes --ref=mycelium--export--internal show "$BLOB_README" 2>/dev/null || echo "NO_NOTE")
if [[ "$EXPORT_RC" -ne 0 ]] && [[ "$EDGE_EXPORT" == "NO_NOTE" ]]; then
  echo "  ✓ export: nonexistent note fails with error"
  PASS=$((PASS + 1))
else
  echo "  ✗ export: should fail for nonexistent note (exit=$EXPORT_RC)"
  FAIL=$((FAIL + 1))
fi

# Export of commit note includes edges
$MYCELIUM note -f HEAD -k decision -t "Commit decision" -m "A decision." >/dev/null 2>&1
COMMIT=$(git rev-parse HEAD)
out=$($MYCELIUM export "$COMMIT" --audience internal 2>&1) || true
COMMIT_EXPORT=$(git notes --ref=mycelium--export--internal show "$COMMIT" 2>/dev/null || echo "")
assert "export: commit note has explains edge" "explains" "$COMMIT_EXPORT"

# Export with custom edges preserves them
$MYCELIUM note -f src/main.ts -k warning -t "Fragile" \
  -e "depends-on blob:$BLOB_README" \
  -m "Handle with care." >/dev/null 2>&1
BLOB_MAIN=$(git rev-parse HEAD:src/main.ts)
$MYCELIUM export "$BLOB_MAIN" --audience internal >/dev/null 2>&1 || true
EDGE_EXPORT=$(git notes --ref=mycelium--export--internal show "$BLOB_MAIN" 2>/dev/null || echo "")
assert "export: custom edges preserved" "depends-on" "$EDGE_EXPORT"
assert "export: targets-path preserved" "targets-path" "$EDGE_EXPORT"

# Export of root tree note (project-level)
$MYCELIUM note -f . -k constraint -t "Project rule" -m "Always test." >/dev/null 2>&1
ROOT_TREE=$(git rev-parse HEAD^{tree})
$MYCELIUM export . --audience internal >/dev/null 2>&1 || true
ROOT_EXPORT=$(git notes --ref=mycelium--export--internal show "$ROOT_TREE" 2>/dev/null || echo "")
assert "export: root tree note exportable" "Project rule" "$ROOT_EXPORT"

# Export of directory note
mkdir -p lib
echo "util" > lib/util.ts
git add lib && git commit -q --no-verify -m "add lib" 2>/dev/null
$MYCELIUM note -f lib -k constraint -t "Lib rules" -m "No side effects." >/dev/null 2>&1
TREE_LIB=$(git rev-parse HEAD:lib)
$MYCELIUM export lib --audience internal >/dev/null 2>&1 || true
LIB_EXPORT=$(git notes --ref=mycelium--export--internal show "$TREE_LIB" 2>/dev/null || echo "")
assert "export: directory note exportable" "Lib rules" "$LIB_EXPORT"


# =====================================================================
echo ""
echo "=== doctor with exports ==="

cd "$REPO_EDGE"

# Doctor should report export ref note counts
out=$($MYCELIUM doctor 2>&1)
assert "doctor: reports notes count" "notes" "$out"

# TODO Phase 1: doctor should distinguish local vs exported vs imported notes
# and report export ref health. For now, just verify doctor doesn't crash.
# assert "doctor: shows export count" "exported:" "$out"


# =====================================================================
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
