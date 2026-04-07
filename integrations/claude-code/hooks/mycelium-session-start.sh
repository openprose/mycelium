#!/usr/bin/env bash
# Mycelium SessionStart hook — inject skill + high-signal notes on new sessions.
set -euo pipefail

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && exit 0

# Only run in git repos with mycelium notes
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0
git notes --ref=mycelium list &>/dev/null || exit 0
NOTE_COUNT=$(git notes --ref=mycelium list 2>/dev/null | wc -l)
[ "$NOTE_COUNT" -eq 0 ] && exit 0

# Find mycelium.sh
MYCELIUM=""
for loc in "${HOME}/.local/bin/mycelium.sh" "${HOME}/.agents/skills/mycelium/mycelium.sh"; do
  [ -x "$loc" ] && MYCELIUM="$loc" && break
done
[ -z "$MYCELIUM" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel)

parts="[mycelium] This repo has ${NOTE_COUNT} mycelium note(s)."
parts="${parts}\n\nUse \`mycelium.sh read <file>\` to check notes before working on a file."
parts="${parts}\nUse \`mycelium.sh note <file> -k <kind> -m \"...\"\` to leave notes after meaningful work."

# Inject SKILL.md — check repo root, plugin root, then global locations
SKILL=""
for loc in "${REPO_ROOT}/SKILL.md" "${CLAUDE_PLUGIN_ROOT:-}/SKILL.md" "${HOME}/.claude/skills/mycelium/SKILL.md" "${HOME}/.local/share/mycelium/SKILL.md"; do
  if [ -n "$loc" ] && [ -f "$loc" ]; then
    SKILL=$(cat "$loc")
    break
  fi
done
if [ -n "$SKILL" ]; then
  parts="${parts}\n\n## Mycelium Skill\n${SKILL}"
fi

# Constraints — project rules
constraints=$("$MYCELIUM" find constraint 2>/dev/null || true)
if [ -n "$constraints" ]; then
  parts="${parts}\n\n## Constraints\n${constraints}"
fi

# Warnings — known fragile things
warnings=$("$MYCELIUM" find warning 2>/dev/null || true)
if [ -n "$warnings" ]; then
  parts="${parts}\n\n## Warnings\n${warnings}"
fi

# Graph state — pipe through cat to avoid SIGPIPE in non-terminal contexts
doctor=$("$MYCELIUM" doctor 2>/dev/null | cat || true)
if [ -n "$doctor" ]; then
  parts="${parts}\n\n## Graph state\n${doctor}"
fi

# Escape for JSON
context=$(printf '%s' "$parts" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":${context}}}
EOF
