#!/usr/bin/env bash
# Mycelium PostToolUse(Edit|Write) hook — track changed files for stop nudge.
set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ] || [ -z "$CWD" ] && exit 0

# Only track in git repos with mycelium notes
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
[ "$(git notes --ref=mycelium list 2>/dev/null | wc -l)" -eq 0 ] && exit 0

# Convert to repo-relative
REPO_ROOT=$(git rev-parse --show-toplevel)
REL_PATH="${FILE_PATH#"${REPO_ROOT}/"}"
[[ "$REL_PATH" == /* ]] && exit 0

# Append to state file
STATE="/tmp/mycelium-cc-${SESSION_ID}.changed"
echo "$REL_PATH" >> "$STATE"

exit 0
