#!/usr/bin/env bash
# Mycelium PostToolUse(Read) hook — inject per-file notes when a file is read.
# Checks default ref and all slot refs for notes on the file's current blob.
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$FILE_PATH" ] || [ -z "$CWD" ] && exit 0

# Only run in git repos
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Check if mycelium notes exist at all (fast path)
git notes --ref=mycelium list &>/dev/null || exit 0
[ "$(git notes --ref=mycelium list 2>/dev/null | wc -l)" -eq 0 ] && exit 0

# Convert absolute path to repo-relative
REPO_ROOT=$(git rev-parse --show-toplevel)
REL_PATH="${FILE_PATH#"${REPO_ROOT}/"}"

# Skip if file is outside repo
[[ "$REL_PATH" == /* ]] && exit 0

# Resolve blob OID (raw git — no subprocess overhead from mycelium.sh)
OID=$(git rev-parse "HEAD:${REL_PATH}" 2>/dev/null || true)
[ -z "$OID" ] && exit 0

# Collect notes from default ref and all slot refs
all_notes=""

default_note=$(git notes --ref=mycelium show "$OID" 2>/dev/null || true)
if [ -n "$default_note" ]; then
  all_notes="[ref: mycelium]\n${default_note}"
fi

for ref in $(git for-each-ref --format='%(refname:short)' 'refs/notes/mycelium--slot--*' 2>/dev/null); do
  slot_note=$(git notes --ref="$ref" show "$OID" 2>/dev/null || true)
  if [ -n "$slot_note" ]; then
    [ -n "$all_notes" ] && all_notes="${all_notes}\n\n"
    all_notes="${all_notes}[ref: ${ref}]\n${slot_note}"
  fi
done

[ -z "$all_notes" ] && exit 0

context=$(printf '[mycelium] Notes on %s:\n%b' "$REL_PATH" "$all_notes" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":${context}}}
EOF
