#!/usr/bin/env bash
# Mycelium PostToolUse(Edit|Write) hook — track changed files for stop nudge.
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

# Only track in git repos. Fresh repos with no notes yet are valid targets —
# the Stop hook still needs to nudge the agent to leave a first note.
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Convert to repo-relative
REPO_ROOT=$(git rev-parse --show-toplevel)
REL_PATH="${FILE_PATH#"${REPO_ROOT}/"}"
[[ "$REL_PATH" == /* ]] && exit 0

# Append to state file
STATE="/tmp/mycelium-cc-${SESSION_ID}.changed"
echo "$REL_PATH" >> "$STATE"

exit 0
