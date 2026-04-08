#!/usr/bin/env bash
# Mycelium PostToolUse(Edit|Write) hook — remind agent to leave notes after edits.
# Tracks changed files AND injects a per-edit reminder as additionalContext,
# matching the Pi extension's "underground follow-up reminder" pattern.
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  exit 0
fi

# Strict session ID validation — used in a /tmp path, so reject anything
# that could enable path traversal.
[[ "$SESSION_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || exit 0

# Only fire in git repos.
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Convert to repo-relative
REPO_ROOT=$(git rev-parse --show-toplevel)
REL_PATH="${FILE_PATH#"${REPO_ROOT}/"}"
if [[ "$REL_PATH" == /* ]]; then
  exit 0
fi

# Track changed file (for Stop hook if enabled, and for cumulative nudge)
STATE="/tmp/mycelium-cc-${SESSION_ID}.changed"
echo "$REL_PATH" >> "$STATE"

# Build the reminder — show cumulative list of all changed files this session
FILES=$(sort -u "$STATE")
COUNT=$(echo "$FILES" | wc -l)
FILE_LIST=$(echo "$FILES" | sed 's/^/  - /')

context=$(printf '[mycelium] %d file(s) changed this session:\n%s\nRemember to leave mycelium notes before wrapping up: mycelium.sh note <file> -k <kind> -m "..."' "$COUNT" "$FILE_LIST" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":${context}}}
EOF
