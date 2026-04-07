#!/usr/bin/env bash
# Plugin spec compliance test suite
# Tests Claude Code hook scripts and Pi extension against PLUGIN-SPEC.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MYCELIUM="${HOME}/.local/bin/mycelium.sh"
PI_EXT="$REPO_ROOT/mycelium-hook.ts"

HOOK_DIR="$REPO_ROOT/integrations/claude-code/hooks"
HOOK_SESSION="$HOOK_DIR/mycelium-session-start.sh"
HOOK_READ="$HOOK_DIR/mycelium-post-read.sh"
HOOK_WRITE="$HOOK_DIR/mycelium-post-write.sh"
HOOK_STOP="$HOOK_DIR/mycelium-stop.sh"

TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# --- test harness (matches test/test.sh style) ---

ok()  { PASS=$((PASS + 1)); echo "  ✓ $1"; }
die() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

assert() {
  local name="$1"
  if eval "$2"; then
    ok "$name"
  else
    die "$name"
  fi
}

run_hook() {
  local hook="$1" json="$2"
  echo "$json" | "$hook" 2>/dev/null || true
}

# --- setup test repo ---

cd "$TEST_DIR"
git init -q
git config user.email "test@test"
git config user.name "test"

# Create SKILL.md
cat > SKILL.md <<'SKILL'
# Mycelium Skill

Use mycelium.sh to read and write notes on code.
SKILL

# Create src/auth.ts with content
mkdir -p src
cat > src/auth.ts <<'CODE'
export function authenticate(user: string) {
  return checkCredentials(user);
}
CODE

# Create src/utils.ts (no notes)
cat > src/utils.ts <<'CODE'
export function formatDate(d: Date) {
  return d.toISOString();
}
CODE

git add .
git commit -q --no-verify -m "initial commit"

REPO_ROOT_TMP="$TEST_DIR"
AUTH_BLOB=$(git rev-parse HEAD:src/auth.ts)
TREE_ROOT=$(git rev-parse HEAD^{tree})

# Add mycelium notes
# 1. Warning note on src/auth.ts (default ref)
git notes --ref=mycelium add -m "$(cat <<'NOTE'
kind warning
title Auth module is fragile
---
Do not modify without integration tests.
NOTE
)" "$AUTH_BLOB"

# 2. Slot note on src/auth.ts (review slot)
git notes --ref=mycelium--slot--review add -m "$(cat <<'NOTE'
kind observation
title Security review pending
---
Needs review before release.
NOTE
)" "$AUTH_BLOB"

# 3. Constraint note on root tree
git notes --ref=mycelium add -m "$(cat <<'NOTE'
kind constraint
title All changes require tests
---
Every PR must include test coverage.
NOTE
)" "$TREE_ROOT"

# 4. Warning note on root tree (append to existing)
git notes --ref=mycelium append -m "$(cat <<'NOTE'

---
kind warning
title Database migrations are manual
---
Run migrations by hand after deploy.
NOTE
)" "$TREE_ROOT"

# Unique session ID for state file tests
SESSION_ID="test-$$-$(date +%s)"

# ============================================================
echo "=== Session Start ==="
# ============================================================

# Test 1: Session start output contains "mycelium"
out=$(run_hook "$HOOK_SESSION" "{\"cwd\":\"$TEST_DIR\"}")
assert "session start output contains mycelium" \
  'echo "$out" | grep -qi "mycelium"'

# Test 2: Session start output contains SKILL.md content
assert "session start output contains SKILL.md content" \
  'echo "$out" | grep -q "Mycelium Skill"'

# Test 3: Session start output contains constraint
assert "session start output contains constraint" \
  'echo "$out" | grep -qi "constraint"'

# Test 4: Session start output contains warning
assert "session start output contains warning" \
  'echo "$out" | grep -qi "warning"'

# Test 5: Session start in non-git dir produces no output
NOGIT=$(mktemp -d)
out_nogit=$(run_hook "$HOOK_SESSION" "{\"cwd\":\"$NOGIT\"}")
assert "session start in non-git dir produces no output" \
  '[ -z "$out_nogit" ]'
rm -rf "$NOGIT"

# Test 6: Session start in git repo without mycelium notes produces no output
EMPTY_GIT=$(mktemp -d)
git -C "$EMPTY_GIT" init -q
git -C "$EMPTY_GIT" config user.email "t@t"
git -C "$EMPTY_GIT" config user.name "t"
touch "$EMPTY_GIT/f.txt"
git -C "$EMPTY_GIT" add . && git -C "$EMPTY_GIT" commit -q --no-verify -m "init"
out_empty=$(run_hook "$HOOK_SESSION" "{\"cwd\":\"$EMPTY_GIT\"}")
assert "session start in repo without mycelium notes produces no output" \
  '[ -z "$out_empty" ]'
rm -rf "$EMPTY_GIT"

echo ""

# ============================================================
echo "=== Per-file Read ==="
# ============================================================

READ_JSON="{\"cwd\":\"$TEST_DIR\",\"tool_input\":{\"file_path\":\"$TEST_DIR/src/auth.ts\"}}"

# Test 7: Reading annotated file returns note content from default ref
out=$(run_hook "$HOOK_READ" "$READ_JSON")
assert "reading annotated file returns default ref note" \
  'echo "$out" | grep -q "Auth module is fragile"'

# Test 8: Reading annotated file returns note content from slot ref
assert "reading annotated file returns slot ref note" \
  'echo "$out" | grep -q "Security review pending"'

# Test 9: Reading annotated file output contains [ref: labels
assert "reading annotated file output contains ref labels" \
  'echo "$out" | grep -q "\[ref:"'

# Test 10: Reading unannotated file produces no output
UNANNOTATED_JSON="{\"cwd\":\"$TEST_DIR\",\"tool_input\":{\"file_path\":\"$TEST_DIR/src/utils.ts\"}}"
out_unann=$(run_hook "$HOOK_READ" "$UNANNOTATED_JSON")
assert "reading unannotated file produces no output" \
  '[ -z "$out_unann" ]'

# Test 11: Reading file outside repo produces no output
OUTSIDE_JSON="{\"cwd\":\"$TEST_DIR\",\"tool_input\":{\"file_path\":\"/etc/passwd\"}}"
out_outside=$(run_hook "$HOOK_READ" "$OUTSIDE_JSON")
assert "reading file outside repo produces no output" \
  '[ -z "$out_outside" ]'

# Test 12: Reading file in non-git dir produces no output
NOGIT2=$(mktemp -d)
touch "$NOGIT2/file.txt"
NOGIT_JSON="{\"cwd\":\"$NOGIT2\",\"tool_input\":{\"file_path\":\"$NOGIT2/file.txt\"}}"
out_nogit2=$(run_hook "$HOOK_READ" "$NOGIT_JSON")
assert "reading file in non-git dir produces no output" \
  '[ -z "$out_nogit2" ]'
rm -rf "$NOGIT2"

echo ""

# ============================================================
echo "=== Mutation Tracking ==="
# ============================================================

# Clean up any prior state
rm -f "/tmp/mycelium-cc-${SESSION_ID}.changed"

# Test 13: Post-write creates state file with relative path
WRITE_JSON="{\"cwd\":\"$TEST_DIR\",\"session_id\":\"$SESSION_ID\",\"tool_input\":{\"file_path\":\"$TEST_DIR/src/auth.ts\"}}"
run_hook "$HOOK_WRITE" "$WRITE_JSON" >/dev/null
STATE="/tmp/mycelium-cc-${SESSION_ID}.changed"
assert "post-write creates state file with relative path" \
  '[ -f "$STATE" ] && grep -q "src/auth.ts" "$STATE"'

# Test 14: Post-write appends (not overwrites) on second call
WRITE_JSON2="{\"cwd\":\"$TEST_DIR\",\"session_id\":\"$SESSION_ID\",\"tool_input\":{\"file_path\":\"$TEST_DIR/src/utils.ts\"}}"
run_hook "$HOOK_WRITE" "$WRITE_JSON2" >/dev/null
assert "post-write appends on second call" \
  'grep -q "src/auth.ts" "$STATE" && grep -q "src/utils.ts" "$STATE"'

# Test 15: Post-write in non-mycelium repo creates no state file
NON_MYCEL=$(mktemp -d)
git -C "$NON_MYCEL" init -q
git -C "$NON_MYCEL" config user.email "t@t"
git -C "$NON_MYCEL" config user.name "t"
touch "$NON_MYCEL/f.txt"
git -C "$NON_MYCEL" add . && git -C "$NON_MYCEL" commit -q --no-verify -m "init"
NM_SESSION="nonmycel-$$"
NM_JSON="{\"cwd\":\"$NON_MYCEL\",\"session_id\":\"$NM_SESSION\",\"tool_input\":{\"file_path\":\"$NON_MYCEL/f.txt\"}}"
run_hook "$HOOK_WRITE" "$NM_JSON" >/dev/null
assert "post-write in non-mycelium repo creates no state file" \
  '[ ! -f "/tmp/mycelium-cc-${NM_SESSION}.changed" ]'
rm -rf "$NON_MYCEL"

# Clean up state from tracking tests for stop tests
rm -f "$STATE"

echo ""

# ============================================================
echo "=== Stop Nudge ==="
# ============================================================

# Set up state file for stop tests
STOP_SESSION="stop-$$-$(date +%s)"
STOP_STATE="/tmp/mycelium-cc-${STOP_SESSION}.changed"
printf 'src/auth.ts\nsrc/utils.ts\n' > "$STOP_STATE"

STOP_JSON="{\"cwd\":\"$TEST_DIR\",\"session_id\":\"$STOP_SESSION\",\"stop_hook_active\":false}"

# Test 16: Stop with tracked files emits "decision":"block" JSON
out=$(run_hook "$HOOK_STOP" "$STOP_JSON")
assert "stop with tracked files emits decision block" \
  'echo "$out" | grep -q "\"decision\":\"block\""'

# Test 17: Stop with tracked files lists the file paths
assert "stop with tracked files lists file paths" \
  'echo "$out" | grep -q "src/auth.ts" && echo "$out" | grep -q "src/utils.ts"'

# Test 18: Stop with stop_hook_active=true exits silently
# Re-create state file (previous stop cleaned it up)
printf 'src/auth.ts\n' > "$STOP_STATE"
STOP_ACTIVE_JSON="{\"cwd\":\"$TEST_DIR\",\"session_id\":\"$STOP_SESSION\",\"stop_hook_active\":true}"
out_active=$(run_hook "$HOOK_STOP" "$STOP_ACTIVE_JSON")
assert "stop with stop_hook_active=true exits silently" \
  '[ -z "$out_active" ]'

# Test 19: Stop with no state file exits silently
rm -f "$STOP_STATE"
out_nostate=$(run_hook "$HOOK_STOP" "$STOP_JSON")
assert "stop with no state file exits silently" \
  '[ -z "$out_nostate" ]'

# Test 20: Stop cleans up state file
printf 'src/auth.ts\n' > "$STOP_STATE"
run_hook "$HOOK_STOP" "$STOP_JSON" >/dev/null
assert "stop cleans up state file" \
  '[ ! -f "$STOP_STATE" ]'

echo ""

# ============================================================
echo "=== Pi Extension Structure ==="
# ============================================================

PI=$(<"$PI_EXT")

# Test 21: Pi extension has before_agent_start handler
assert "pi extension has before_agent_start handler" \
  'echo "$PI" | grep -q "before_agent_start"'

# Test 22: Pi extension has tool_result handler checking "read"
assert "pi extension has tool_result handler checking read" \
  'echo "$PI" | grep -q "tool_result" && echo "$PI" | grep -q "\"read\""'

# Test 23: Pi extension has tool_result handler checking "write" or "edit"
assert "pi extension has tool_result handler checking write or edit" \
  'echo "$PI" | grep -q "\"write\"" || echo "$PI" | grep -q "\"edit\""'

# Test 24: Pi extension has agent_end handler
assert "pi extension has agent_end handler" \
  'echo "$PI" | grep -q "agent_end"'

# Test 25: Pi extension references "find constraint"
assert "pi extension references find constraint" \
  'echo "$PI" | grep -q "find constraint"'

# Test 26: Pi extension references "find warning"
assert "pi extension references find warning" \
  'echo "$PI" | grep -q "find warning"'

# Test 27: Pi extension references SKILL.md / SKILL_MD
assert "pi extension references SKILL.md" \
  'echo "$PI" | grep -qi "skill.md\|SKILL_MD"'

# Test 28: Pi extension references mycelium--slot--
assert "pi extension references mycelium--slot--" \
  'echo "$PI" | grep -q "mycelium--slot--"'

# Test 29: Pi extension uses display: false on messages
assert "pi extension uses display: false on messages" \
  'echo "$PI" | grep -q "display: false"'

echo ""

# ============================================================
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
