#!/usr/bin/env bash
# mycelium gitleaks integration tests
# Verifies secret scanning works across all layers:
#   1. gitleaks baseline (confirms detection works at all)
#   2. mycelium.sh inline scan (blocks note creation)
#   3. pre-commit hook (blocks commits with secrets)
#   4. pre-push hook (full scan including refs/notes/*)
#   5. git log --all covers notes refs
#
# gitleaks is strongly recommended but not a strict dependency.
# When absent, mycelium works normally — these tests verify
# the integration when it IS present.
set -euo pipefail

MYCELIUM="$(cd "$(dirname "$0")" && pwd)/mycelium.sh"
TMPDIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Use real git binary (some setups wrap git push)
GIT=/usr/bin/git
[[ -x "$GIT" ]] || GIT=$(command -v git)

# --- test harness ---

assert_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected success, got failure)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✗ $name (expected failure, got success)"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local name="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF "$expected"; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
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

# --- preflight ---

if ! command -v gitleaks &>/dev/null; then
  echo "SKIP: gitleaks not installed (strongly recommended, not required)"
  exit 0
fi

# --- test secret (fake, safe to have in source) ---

SLACK_TOKEN="xoxb-1234567890123-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"

# --- setup test repo ---

cd "$TMPDIR"
$GIT init -q
$GIT config user.email "test@test"
$GIT config user.name "test"
$GIT config core.hooksPath .git/hooks
echo "clean" > readme.md
$GIT add .
$GIT commit -q --no-verify -m "init"

echo ""
echo "=== Gitleaks Baseline ==="

# Verify detection works at all
tmpd=$(mktemp -d)
echo "$SLACK_TOKEN" > "$tmpd/s.txt"
assert_fail "detects slack token in file" \
  gitleaks dir --no-banner "$tmpd"
rm -r "$tmpd"

# Verify clean content passes
tmpd=$(mktemp -d)
echo "nothing to see here" > "$tmpd/clean.txt"
assert_ok "passes clean file" \
  gitleaks dir --no-banner "$tmpd"
rm -r "$tmpd"

echo ""
echo "=== Mycelium Inline Scan ==="

assert_ok "allows clean note" \
  "$MYCELIUM" note HEAD -k observation -m "this is perfectly fine"

assert_fail "blocks slack token in body" \
  "$MYCELIUM" note HEAD -k observation -m "token: $SLACK_TOKEN"

# Verify blocked note was NOT persisted
out=$("$MYCELIUM" read HEAD 2>/dev/null)
assert_contains "blocked note not persisted" "perfectly fine" "$out"
assert_not_contains "secret not in stored note" "xoxb-" "$out"

assert_fail "blocks slack token in title" \
  "$MYCELIUM" note HEAD -k warning -t "$SLACK_TOKEN" -m "oops"

multiline="line one
line two
password: $SLACK_TOKEN
line four"
assert_fail "blocks secret in multi-line note" \
  "$MYCELIUM" note HEAD -k context -m "$multiline"

assert_ok "allows benign 'token' word" \
  "$MYCELIUM" note HEAD -k observation -m "the token count was 42"

assert_ok "allows note with no body" \
  "$MYCELIUM" note HEAD -k observation

long_body=$(python3 -c "print('clean line\n' * 500)")
assert_ok "allows long clean note" \
  "$MYCELIUM" note HEAD -k context -m "$long_body"

echo ""
echo "=== Pre-commit Hook ==="

mkdir -p .git/hooks
cat > .git/hooks/pre-commit << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v gitleaks &>/dev/null; then exit 0; fi
gitleaks git --staged --no-banner --redact -l warn
HOOK
chmod +x .git/hooks/pre-commit

echo "safe content" > safe.txt
$GIT add safe.txt
assert_ok "allows clean commit" \
  $GIT commit -q -m "safe"

echo "token=$SLACK_TOKEN" > leaked.txt
$GIT add leaked.txt
assert_fail "blocks commit with staged secret" \
  $GIT commit -q -m "oops"
$GIT reset -q HEAD -- leaked.txt
rm -f leaked.txt

echo ""
echo "=== Pre-push Hook ==="

# Each push test uses a fresh repo to avoid history poisoning.
# git notes remove leaves the "add" commit in --all history,
# so a secret once added to any ref is permanent in the log.

# --- clean push ---
pushdir=$(mktemp -d)
cd "$pushdir"
$GIT init -q
$GIT config user.email "test@test"
$GIT config user.name "test"
$GIT config core.hooksPath .git/hooks
echo "init" > r.md && $GIT add . && $GIT commit -q --no-verify -m "init"
$GIT clone -q --bare . "$pushdir/remote.git"
$GIT remote add test-remote "$pushdir/remote.git"

mkdir -p .git/hooks
cat > .git/hooks/pre-push << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v gitleaks &>/dev/null; then exit 0; fi
gitleaks git --no-banner --redact -l warn
HOOK
chmod +x .git/hooks/pre-push

echo "clean" > c.txt && $GIT add c.txt && $GIT commit -q --no-verify -m "clean"
assert_ok "allows clean push" \
  $GIT push -q test-remote master

# --- poisoned note push ---
pushdir2=$(mktemp -d)
cd "$pushdir2"
$GIT init -q
$GIT config user.email "test@test"
$GIT config user.name "test"
$GIT config core.hooksPath .git/hooks
echo "init" > r.md && $GIT add . && $GIT commit -q --no-verify -m "init"
$GIT clone -q --bare . "$pushdir2/remote.git"
$GIT remote add test-remote "$pushdir2/remote.git"

mkdir -p .git/hooks
cat > .git/hooks/pre-push << 'HOOK'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v gitleaks &>/dev/null; then exit 0; fi
gitleaks git --no-banner --redact -l warn
HOOK
chmod +x .git/hooks/pre-push

$GIT notes --ref=push-test add -f -m "$SLACK_TOKEN" HEAD
assert_fail "blocks push with secret in note" \
  $GIT push -q test-remote master

cd "$TMPDIR"

echo ""
echo "=== Git Log --all Covers Notes ==="

# Separate repo so the poisoned note doesn't affect other tests
notesdir=$(mktemp -d)
cd "$notesdir"
$GIT init -q
$GIT config user.email "test@test"
$GIT config user.name "test"
echo "init" > r.md && $GIT add . && $GIT commit -q --no-verify -m "init"

$GIT notes --ref=gitleaks-test add -f -m "$SLACK_TOKEN" HEAD
out=$(gitleaks git --no-banner -v -l warn 2>&1 || true)
assert_contains "catches secret in raw git note" "slack-bot-token" "$out"

cd "$TMPDIR"

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
