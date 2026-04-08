#!/usr/bin/env bash
# Mycelium PostToolUse(Read) hook — inject per-file notes when a file is read.
# Checks default ref and all slot refs for notes on the file's current blob.
# Text notes are injected as content. Non-text notes (binary, images, HTML)
# are described by type/size so the agent can decide how to view them.
set -euo pipefail

# Max bytes of text note content to inject. Larger notes are truncated.
MAX_NOTE_BYTES=4096

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$FILE_PATH" ] || [ -z "$CWD" ] && exit 0

# Only run in git repos
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Fast path: if no notes exist anywhere, nothing to inject.
# (Fresh repos are handled by session-start/stop hooks, not post-read.)
[ "$(git notes --ref=mycelium list 2>/dev/null | wc -l)" -eq 0 ] && exit 0

# Convert absolute path to repo-relative
REPO_ROOT=$(git rev-parse --show-toplevel)
REL_PATH="${FILE_PATH#"${REPO_ROOT}/"}"

# Skip if file is outside repo
[[ "$REL_PATH" == /* ]] && exit 0

# Resolve blob OID (raw git — no subprocess overhead from mycelium.sh)
OID=$(git rev-parse "HEAD:${REL_PATH}" 2>/dev/null || true)
[ -z "$OID" ] && exit 0

# Classify a git note blob and return either its text content or a descriptor.
# Usage: format_note <noteblob_oid> <ref_label>
# Text notes: outputs content (truncated if over MAX_NOTE_BYTES).
# Non-text notes: outputs a one-line descriptor with type and size.
format_note() {
  local blob="$1" label="$2"
  local size mime_type

  # Get blob size and MIME type without reading full content
  size=$(git cat-file -s "$blob" 2>/dev/null || echo 0)
  mime_type=$(git cat-file -p "$blob" 2>/dev/null | file -b --mime-type - 2>/dev/null || echo "application/octet-stream")

  # Non-text content — show descriptor so agent can decide how to view it
  if ! echo "$mime_type" | grep -q "^text/"; then
    local human_size
    if [ "$size" -ge 1048576 ]; then
      human_size="$((size / 1048576))MB"
    elif [ "$size" -ge 1024 ]; then
      human_size="$((size / 1024))KB"
    else
      human_size="${size}B"
    fi
    echo "[${label}] (non-text note: ${mime_type}, ${human_size}) — use \`git notes --ref=${label} show ${OID}\` to retrieve"
    return
  fi

  # Text content — read and check size
  local text
  text=$(git cat-file -p "$blob" 2>/dev/null || true)
  [ -z "$text" ] && return

  if [ "$size" -gt "$MAX_NOTE_BYTES" ]; then
    local truncated
    truncated=$(echo "$text" | head -c "$MAX_NOTE_BYTES")
    echo "[${label}]"
    echo "$truncated"
    echo "... (truncated, ${size} bytes total — use \`git notes --ref=${label} show ${OID}\` for full content)"
  else
    echo "[${label}]"
    echo "$text"
  fi
}

# Collect notes from default ref and all slot refs
all_notes=""

# Look up the note blob OID (not the note content) for the default ref
default_noteblob=$(git notes --ref=mycelium list "$OID" 2>/dev/null | cut -d' ' -f1 || true)
if [ -n "$default_noteblob" ]; then
  all_notes=$(format_note "$default_noteblob" "mycelium")
fi

for ref in $(git for-each-ref --format='%(refname:short)' 'refs/notes/mycelium--slot--*' 2>/dev/null); do
  slot_noteblob=$(git notes --ref="$ref" list "$OID" 2>/dev/null | cut -d' ' -f1 || true)
  if [ -n "$slot_noteblob" ]; then
    local_note=$(format_note "$slot_noteblob" "$ref")
    if [ -n "$local_note" ]; then
      [ -n "$all_notes" ] && all_notes="${all_notes}

"
      all_notes="${all_notes}${local_note}"
    fi
  fi
done

[ -z "$all_notes" ] && exit 0

context=$(printf '[mycelium] Notes on %s:\n%s' "$REL_PATH" "$all_notes" | jq -Rs .)

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":${context}}}
EOF
