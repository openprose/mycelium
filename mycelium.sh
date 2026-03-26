#!/usr/bin/env bash
# mycelium — git-native note graph
# No dependencies beyond git and bash.
set -euo pipefail

REF="${MYCELIUM_REF:-mycelium}"
NOTES_REF="refs/notes/$REF"

# --- helpers ---

obj_label() {
  local oid="$1"
  local type
  type=$(git cat-file -t "$oid" 2>/dev/null || echo "unknown")
  case "$type" in
    commit) echo "commit:${oid:0:12}" ;;
    blob)   echo "  blob:${oid:0:12}" ;;
    tree)   echo "  tree:${oid:0:12}" ;;
    tag)    echo "   tag:${oid:0:12}" ;;
    *)      echo "    ??:${oid:0:12}" ;;
  esac
}

note_header() {
  echo "$1" | grep "^$2 " | head -1 | sed "s/^$2 //"
}

# Resolve a target to (oid, type, path-if-any).
# Accepts: OID, HEAD, ref, file path, directory path.
resolve_target() {
  local target="$1"
  local at="${2:-HEAD}"

  # Try as a file/dir path first (relative to repo root)
  if [[ -e "$target" ]] || git rev-parse --verify "$at:$target" &>/dev/null 2>&1; then
    local oid
    oid=$(git rev-parse "$at:$target" 2>/dev/null) || true
    if [[ -n "$oid" ]]; then
      local type
      type=$(git cat-file -t "$oid" 2>/dev/null)
      echo "$oid $type $target"
      return
    fi
  fi

  # Try as a git ref (HEAD, branch, tag, OID)
  local oid
  oid=$(git rev-parse --verify "$target" 2>/dev/null) \
    || { echo "Error: cannot resolve '$target'" >&2; return 1; }
  local type
  type=$(git cat-file -t "$oid" 2>/dev/null || echo "unknown")
  echo "$oid $type"
}

# --- commands ---

usage() {
  cat <<'EOF'
mycelium — structured notes on git objects

  mycelium note [target] -k <kind> [-m <body>]   Write a note (default: HEAD)
  mycelium read [target]                          Read note (default: HEAD)
  mycelium context <path> [ref]                   All notes relevant to a path
  mycelium find <kind>                            Find all notes of a kind
  mycelium edges [type]                           List all edges
  mycelium list                                   List all annotated objects
  mycelium log [n]                                Recent commits with notes
  mycelium dump                                   All notes, greppable
  mycelium activate                               Show notes in git log
  mycelium sync-init [remote]                     Configure fetch/push

Targets: HEAD (default), commit ref, file path, directory path, OID.
Auto-edges: commit→explains, blob→applies-to+targets-path, tree→applies-to+targets-treepath.

Options for 'note':
  -k, --kind <kind>         Required. decision|context|summary|warning|constraint|observation
  -e, --edge <type target>  Extra edges (auto-edges are always added)
  -t, --title <title>       Short label
  -s, --status <status>     active (default)|superseded|archived
  --supersedes <oid>        OID of note this replaces
  -m, --message <body>      Note body (reads stdin if omitted and not a tty)
EOF
}

cmd_note() {
  local target="" kind="" title="" status="" body="" supersedes=""
  local -a edges=()

  # Parse args — target is the first non-flag argument, or HEAD
  while [[ $# -gt 0 ]]; do
    case $1 in
      -k|--kind)       kind="$2"; shift 2 ;;
      -e|--edge)       edges+=("$2"); shift 2 ;;
      -t|--title)      title="$2"; shift 2 ;;
      -s|--status)     status="$2"; shift 2 ;;
      --supersedes)    supersedes="$2"; shift 2 ;;
      -m|--message)    body="$2"; shift 2 ;;
      -*)              echo "Unknown option: $1" >&2; exit 1 ;;
      *)               target="$1"; shift ;;
    esac
  done

  target="${target:-HEAD}"
  [[ -z "$kind" ]] && { echo "Error: --kind is required" >&2; exit 1; }

  # Read body from stdin if not provided
  if [[ -z "$body" ]] && [[ ! -t 0 ]]; then
    body=$(cat)
  fi

  # Resolve target
  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  # Build auto-edges based on object type
  local -a auto_edges=()
  case "$type" in
    commit)
      auto_edges+=("explains commit:$oid")
      ;;
    blob)
      auto_edges+=("applies-to blob:$oid")
      [[ -n "$filepath" ]] && auto_edges+=("targets-path path:$filepath")
      ;;
    tree)
      auto_edges+=("applies-to tree:$oid")
      [[ -n "$filepath" ]] && auto_edges+=("targets-treepath treepath:$filepath")
      ;;
  esac

  # Build note content
  local content="kind $kind"
  [[ -n "$title" ]]      && content+=$'\n'"title $title"
  [[ -n "$status" ]]     && content+=$'\n'"status $status"
  [[ -n "$supersedes" ]] && content+=$'\n'"supersedes $supersedes"
  for e in "${auto_edges[@]}"; do
    content+=$'\n'"edge $e"
  done
  for e in "${edges[@]}"; do
    content+=$'\n'"edge $e"
  done
  if [[ -n "$body" ]]; then
    content+=$'\n\n'"$body"
  fi

  git notes --ref="$REF" add -f -m "$content" "$oid"
  echo "$oid"
}

cmd_read() {
  local target="${1:-HEAD}"
  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  if [[ -n "$filepath" ]]; then
    echo "$type:${oid:0:12} ($filepath)"
  else
    echo "$type:${oid:0:12}"
  fi
  git notes --ref="$REF" show "$oid" 2>/dev/null \
    || echo "(no mycelium note)"
}

cmd_context() {
  local filepath="$1"
  local at="${2:-HEAD}"

  echo "=== context: $filepath @ $at ==="
  echo ""

  # 1. Note on the file's blob
  local blob
  blob=$(git rev-parse "$at:$filepath" 2>/dev/null || true)
  if [[ -n "$blob" ]]; then
    local note
    note=$(git notes --ref="$REF" show "$blob" 2>/dev/null || true)
    if [[ -n "$note" ]]; then
      local kind=$(note_header "$note" "kind")
      local title=$(note_header "$note" "title")
      echo "[blob] ${title:-$filepath} ($kind)"
      echo "$note"
      echo ""
    fi
  fi

  # 2. Walk parent directories for tree notes
  local dir="$filepath"
  while true; do
    dir=$(dirname "$dir")
    local tree
    tree=$(git rev-parse "$at:$dir" 2>/dev/null || true)
    if [[ -n "$tree" ]]; then
      local note
      note=$(git notes --ref="$REF" show "$tree" 2>/dev/null || true)
      if [[ -n "$note" ]]; then
        local kind=$(note_header "$note" "kind")
        local title=$(note_header "$note" "title")
        echo "[tree] ${title:-$dir/} ($kind) — inherited"
        echo "$note"
        echo ""
      fi
    fi
    [[ "$dir" == "." || "$dir" == "/" ]] && break
  done

  # 3. Note on the commit
  local commit
  commit=$(git rev-parse "$at" 2>/dev/null || true)
  if [[ -n "$commit" ]]; then
    local note
    note=$(git notes --ref="$REF" show "$commit" 2>/dev/null || true)
    if [[ -n "$note" ]]; then
      local kind=$(note_header "$note" "kind")
      local title=$(note_header "$note" "title")
      echo "[commit] ${title:-$at} ($kind)"
      echo "$note"
      echo ""
    fi
  fi

  # 4. Other notes that reference this path
  local path_target="path:$filepath"
  git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
    [[ "$obj" == "${blob:-}" || "$obj" == "${commit:-}" ]] && continue
    local content
    content=$(git cat-file -p "$noteblob")
    if echo "$content" | grep -q "edge.*$path_target"; then
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      echo "[edge] ${title:-(untitled)} ($kind) — references $filepath"
      echo "$content"
      echo ""
    fi
  done
}

cmd_edges() {
  local filter="${1:-}"
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    local label=$(obj_label "$obj")
    local edges
    edges=$(git cat-file -p "$blob" | grep '^edge ') || true
    if [[ -n "$edges" ]]; then
      if [[ -z "$filter" ]]; then
        echo "$edges" | sed "s/^/[$label] /"
      else
        echo "$edges" | grep "^edge $filter " | sed "s/^/[$label] /" || true
      fi
    fi
  done
}

cmd_find() {
  local kind="$1"
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    local content
    content=$(git cat-file -p "$blob")
    if echo "$content" | grep -q "^kind $kind\$"; then
      local label=$(obj_label "$obj")
      local title=$(note_header "$content" "title")
      if [[ -n "$title" ]]; then
        echo "$label  $title"
      else
        local body
        body=$(echo "$content" | sed -n '/^$/,$ p' | sed '/^$/d' | head -1)
        echo "$label  ${body:-(no title)}"
      fi
    fi
  done
}

cmd_log() {
  local n="${1:-20}"
  git log --notes="$REF" --oneline -"$n"
}

cmd_list() {
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    local label=$(obj_label "$obj")
    local content
    content=$(git cat-file -p "$blob")
    local kind=$(note_header "$content" "kind")
    local title=$(note_header "$content" "title")
    echo "$label  [$kind] ${title:-}"
  done
}

cmd_activate() {
  git config --add notes.displayRef "$NOTES_REF"
  echo "Mycelium notes now visible in git log."
}

cmd_sync_init() {
  local remote="${1:-origin}"
  git config --add "remote.$remote.fetch" "+$NOTES_REF:$NOTES_REF"
  git config --add "remote.$remote.push" "$NOTES_REF:$NOTES_REF"
  echo "Refspecs added for $remote. Run: git fetch $remote && git push $remote"
}

cmd_dump() {
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    local label=$(obj_label "$obj")
    echo "=== $label ==="
    git cat-file -p "$blob"
    echo
  done
}

# Route
case "${1:-help}" in
  note)       shift; cmd_note "$@" ;;
  read)       shift; cmd_read "$@" ;;
  context)    shift; cmd_context "$@" ;;
  edges)      shift; cmd_edges "$@" ;;
  find)       shift; cmd_find "$@" ;;
  log)        shift; cmd_log "$@" ;;
  list)       cmd_list ;;
  activate)   cmd_activate ;;
  sync-init)  shift; cmd_sync_init "$@" ;;
  dump)       cmd_dump ;;
  help|*)     usage ;;
esac
