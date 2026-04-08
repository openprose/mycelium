#!/usr/bin/env bash
# Mycelium SessionStart hook — inject skill + high-signal notes on new sessions.
set -euo pipefail

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$CWD" ] && exit 0

# Only run in git repos — but proceed even if there are zero notes yet.
# A fresh repo with zero notes is a valid starting point; the plugin's job is
# to teach the agent the protocol so the first note can be written.
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

NOTE_COUNT=$(git notes --ref=mycelium list 2>/dev/null | wc -l)

# Find mycelium.sh — if missing, we can still inject SKILL.md (the protocol),
# but skip the constraint/warning queries.
MYCELIUM=""
for loc in "${HOME}/.local/bin/mycelium.sh" "${HOME}/.agents/skills/mycelium/mycelium.sh"; do
  [ -x "$loc" ] && MYCELIUM="$loc" && break
done

REPO_ROOT=$(git rev-parse --show-toplevel)

if [ "$NOTE_COUNT" -eq 0 ]; then
  parts="[mycelium] This repo has no mycelium notes yet — be the first to leave one."
else
  parts="[mycelium] This repo has ${NOTE_COUNT} mycelium note(s)."
fi
parts="${parts}\n\nUse \`mycelium.sh read <file>\` to check notes before working on a file."
parts="${parts}\nUse \`mycelium.sh note <file> -k <kind> -m \"...\"\` to leave notes after meaningful work."

# Inject SKILL.md — check repo root, then global install locations
SKILL=""
for loc in "${REPO_ROOT}/SKILL.md" "${HOME}/.claude/skills/mycelium/SKILL.md" "${HOME}/.local/share/mycelium/SKILL.md"; do
  if [ -n "$loc" ] && [ -f "$loc" ]; then
    SKILL=$(cat "$loc")
    break
  fi
done
if [ -n "$SKILL" ]; then
  parts="${parts}\n\n## Mycelium Skill\n${SKILL}"
fi

# Constraints and warnings only exist if there are notes already
if [ -n "$MYCELIUM" ] && [ "$NOTE_COUNT" -gt 0 ]; then
  constraints=$("$MYCELIUM" find constraint 2>/dev/null || true)
  if [ -n "$constraints" ]; then
    parts="${parts}\n\n## Constraints\n${constraints}"
  fi

  warnings=$("$MYCELIUM" find warning 2>/dev/null || true)
  if [ -n "$warnings" ]; then
    parts="${parts}\n\n## Warnings\n${warnings}"
  fi
fi

# Escape for JSON
context=$(printf '%s' "$parts" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":${context}}}
EOF
