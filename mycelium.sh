#!/usr/bin/env bash
# mycelium — git-native note graph
# No dependencies beyond git and bash.
set -euo pipefail

REF="${MYCELIUM_REF:-mycelium}"
NOTES_REF="refs/notes/$REF"

usage() {
  cat <<'EOF'
mycelium — structured notes on git objects

  mycelium note <object> [options]     Write a note
  mycelium read <object>               Read note on an object
  mycelium read-path <path> [ref]      Read note on file's current blob
  mycelium edges [type]                List all edges (optionally by type)
  mycelium find <kind>                 Find all notes of a kind
  mycelium log [n]                     Show recent commits with notes
  mycelium list                        List all annotated objects
  mycelium activate                    Add notes to git log display
  mycelium sync-init [remote]          Configure fetch/push refspecs
  mycelium dump                        Dump all notes (for grep/search)

Options for 'note':
  -k, --kind <kind>         Required. decision|context|summary|warning|constraint|observation
  -e, --edge <type target>  Repeatable. e.g. --edge "explains commit:abc123"
  -t, --title <title>       Optional short label
  -s, --status <status>     Optional. active (default)|superseded|archived
  --supersedes <oid>        OID of note this replaces
  -m, --message <body>      Note body (reads stdin if omitted and not a tty)
EOF
}

cmd_note() {
  local object="$1"; shift
  local kind="" title="" status="" body="" supersedes=""
  local -a edges=()

  while [[ $# -gt 0 ]]; do
    case $1 in
      -k|--kind)       kind="$2"; shift 2 ;;
      -e|--edge)       edges+=("$2"); shift 2 ;;
      -t|--title)      title="$2"; shift 2 ;;
      -s|--status)     status="$2"; shift 2 ;;
      --supersedes)    supersedes="$2"; shift 2 ;;
      -m|--message)    body="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  [[ -z "$kind" ]] && { echo "Error: --kind is required" >&2; exit 1; }

  # Read body from stdin if not provided
  if [[ -z "$body" ]] && [[ ! -t 0 ]]; then
    body=$(cat)
  fi

  # Build note content
  local content="kind $kind"
  [[ -n "$title" ]]      && content+=$'\n'"title $title"
  [[ -n "$status" ]]     && content+=$'\n'"status $status"
  [[ -n "$supersedes" ]] && content+=$'\n'"supersedes $supersedes"
  for e in "${edges[@]}"; do
    content+=$'\n'"edge $e"
  done
  if [[ -n "$body" ]]; then
    content+=$'\n\n'"$body"
  fi

  # Resolve object (allow HEAD, branch names, paths)
  local resolved
  resolved=$(git rev-parse --verify "$object" 2>/dev/null) \
    || { echo "Error: cannot resolve '$object'" >&2; exit 1; }

  git notes --ref="$REF" add -f -m "$content" "$resolved"
  echo "$resolved"
}

cmd_read() {
  local object="$1"
  local resolved
  resolved=$(git rev-parse --verify "$object" 2>/dev/null) \
    || { echo "Error: cannot resolve '$object'" >&2; exit 1; }
  git notes --ref="$REF" show "$resolved" 2>/dev/null \
    || echo "(no mycelium note)"
}

cmd_read_path() {
  local filepath="$1"
  local at="${2:-HEAD}"
  local blob
  blob=$(git rev-parse "$at:$filepath" 2>/dev/null) \
    || { echo "Error: cannot resolve '$filepath' at '$at'" >&2; exit 1; }
  echo "blob:$blob ($filepath @ $at)"
  git notes --ref="$REF" show "$blob" 2>/dev/null \
    || echo "(no mycelium note)"
}

cmd_edges() {
  local filter="${1:-}"
  git notes --ref="$REF" list | while read blob obj; do
    local edges
    edges=$(git cat-file -p "$blob" | grep '^edge ')
    if [[ -n "$edges" ]]; then
      if [[ -z "$filter" ]]; then
        echo "$edges" | sed "s/^/[$obj] /"
      else
        echo "$edges" | grep "^edge $filter " | sed "s/^/[$obj] /"
      fi
    fi
  done
}

cmd_find() {
  local kind="$1"
  git notes --ref="$REF" list | while read blob obj; do
    if git cat-file -p "$blob" | grep -q "^kind $kind\$"; then
      local title
      title=$(git cat-file -p "$blob" | grep '^title ' | sed 's/^title //' || true)
      if [[ -n "$title" ]]; then
        echo "$obj  $title"
      else
        echo "$obj"
      fi
    fi
  done
}

cmd_log() {
  local n="${1:-20}"
  git log --notes="$REF" --oneline -"$n"
}

cmd_list() {
  git notes --ref="$REF" list 2>/dev/null
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
  git notes --ref="$REF" list | while read blob obj; do
    echo "=== $obj ==="
    git cat-file -p "$blob"
    echo
  done
}

# Route
case "${1:-help}" in
  note)       shift; cmd_note "$@" ;;
  read)       shift; cmd_read "$@" ;;
  read-path)  shift; cmd_read_path "$@" ;;
  edges)      shift; cmd_edges "$@" ;;
  find)       shift; cmd_find "$@" ;;
  log)        shift; cmd_log "$@" ;;
  list)       cmd_list ;;
  activate)   cmd_activate ;;
  sync-init)  shift; cmd_sync_init "$@" ;;
  dump)       cmd_dump ;;
  help|*)     usage ;;
esac
