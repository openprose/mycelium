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

# Build the payload with REAL newlines (bash string concat does not
# interpret \n escapes, so we use $'...' ANSI-C quoting and printf).
if [ "$NOTE_COUNT" -eq 0 ]; then
  header="[mycelium] This repo has no mycelium notes yet — be the first to leave one."
else
  header="[mycelium] This repo has ${NOTE_COUNT} mycelium note(s)."
fi

parts=$(printf '%s\n\nUse `mycelium.sh read <file>` to check notes before working on a file.\nUse `mycelium.sh note <file> -k <kind> -m "..."` to leave notes after meaningful work.' "$header")

# Inject skill + graph state via `mycelium.sh prime` — the canonical
# user-facing command for surfacing the skill and live repo context.
# Single source of truth: prime finds SKILL.md via its own resolution
# (script dir → git repo root → inline fallback) and emits graph state.
if [ -n "$MYCELIUM" ]; then
  prime_out=$("$MYCELIUM" prime 2>/dev/null | cat || true)
  if [ -n "$prime_out" ]; then
    parts=$(printf '%s\n\n%s' "$parts" "$prime_out")
  fi
fi

# Escape for JSON
context=$(printf '%s' "$parts" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":${context}}}
EOF
