#!/usr/bin/env bash
# Mycelium Stop hook — nudge to leave notes on changed files.
set -euo pipefail

INPUT=$(cat)

# Prevent infinite loop
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_ACTIVE" = "true" ] && exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$SESSION_ID" ] || [ -z "$CWD" ] && exit 0

STATE="/tmp/mycelium-cc-${SESSION_ID}.changed"
[ -f "$STATE" ] || exit 0

# Deduplicate and count
FILES=$(sort -u "$STATE")
[ -z "$FILES" ] && exit 0
COUNT=$(echo "$FILES" | wc -l)

# Only nudge in git repos with mycelium
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
[ "$(git notes --ref=mycelium list 2>/dev/null | wc -l)" -eq 0 ] && exit 0

# Clean up state file
rm -f "$STATE"

# Build file list
FILE_LIST=$(echo "$FILES" | sed 's/^/  - /')

reason=$(printf '📡 %d file(s) changed — consider leaving mycelium notes:\n%s\n\nUse: mycelium.sh note <file> -k <kind> -m "<what future agents should know>"' "$COUNT" "$FILE_LIST" | jq -Rs .)

cat <<EOF
{"decision":"block","reason":${reason}}
EOF
