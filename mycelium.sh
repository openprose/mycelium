#!/usr/bin/env bash
# mycelium — git-native note graph
# No dependencies beyond git and bash.
set -euo pipefail

# Branch selection: env var > .git/mycelium-branch file > default
_git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
if [[ -n "${MYCELIUM_REF:-}" ]]; then
  REF="$MYCELIUM_REF"
elif [[ -f "$_git_dir/mycelium-branch" ]]; then
  REF=$(cat "$_git_dir/mycelium-branch")
else
  REF="mycelium"
fi
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

  # Root tree: "." needs special handling (git rev-parse HEAD:. fails)
  if [[ "$target" == "." ]]; then
    local oid
    oid=$(git rev-parse "$at^{tree}" 2>/dev/null) || true
    if [[ -n "$oid" ]]; then
      echo "$oid tree ."
      return
    fi
  fi

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
  mycelium follow [target]                        Read note + resolve all edges
  mycelium refs [target]                          Find all notes pointing at target
  mycelium context <path> [ref]                   All notes relevant to a path
  mycelium find <kind>                            Find all notes of a kind
  mycelium kinds                                  List all kinds in use
  mycelium edges [type]                           List all edges
  mycelium list                                   List all annotated objects
  mycelium log [n]                                Recent commits with notes
  mycelium dump                                   All notes, greppable
  mycelium branch [use|merge] [name]               Branch-scoped notes
  mycelium activate                               Show notes in git log
  mycelium sync-init [remote]                     Configure fetch/push

Targets: HEAD (default), commit ref, file path, directory path, OID.
Auto-edges: commit→explains, blob→applies-to+targets-path, tree→applies-to+targets-treepath.

Options for 'note':
  -k, --kind <kind>         Required. Any string. Common: decision, context, summary,
                           warning, constraint, observation, value — or invent your own
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

  # Auto-supersede: if this object already has a note, capture its blob OID
  if [[ -z "$supersedes" ]]; then
    local existing_blob
    existing_blob=$(git notes --ref="$REF" list "$oid" 2>/dev/null | cut -d' ' -f1 || true)
    if [[ -n "$existing_blob" ]]; then
      supersedes="$existing_blob"
    fi
  fi

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

  # Scan note body for secrets before writing
  if command -v gitleaks &>/dev/null; then
    local _gl_dir
    _gl_dir=$(mktemp -d)
    printf '%s' "$content" > "$_gl_dir/note.txt"
    if gitleaks dir --no-banner "$_gl_dir" 2>/dev/null; then
      : # clean
    else
      rm -r "$_gl_dir"
      echo "Error: gitleaks detected a secret in this note. Aborting." >&2
      return 1
    fi
    rm -r "$_gl_dir"
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

  # Direct note on this object
  local note
  note=$(git notes --ref="$REF" show "$oid" 2>/dev/null || true)
  if [[ -n "$note" ]]; then
    echo "$note"
    return
  fi

  # No direct note — if this is a path target, scan for stale notes
  # that reference this path but have a different blob OID
  if [[ -n "$filepath" ]]; then
    local path_target="path:$filepath"
    local found=false
    git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
      local content
      content=$(git cat-file -p "$noteblob")
      # Does this note target our path?
      if echo "$content" | grep -q "targets-path $path_target"; then
        local kind=$(note_header "$content" "kind")
        local title=$(note_header "$content" "title")
        echo "(no note on current blob)"
        echo ""
        echo "[stale] ${title:-(untitled)} ($kind) — blob changed, path note still relevant"
        echo "$content"
        found=true
        break
      fi
    done
    # Subshell means $found doesn't propagate — use grep to check
    return
  fi

  echo "(no mycelium note)"
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
      echo "[exact] ${title:-$filepath} ($kind)"
      echo "$note"
      echo ""
    fi
  fi

  # 2. Stale/contextual: notes that target this path but are on a different blob
  local path_target="path:$filepath"
  local seen_objs="${blob:-},"
  git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
    [[ "$obj" == "${blob:-}" ]] && continue
    local content
    content=$(git cat-file -p "$noteblob")
    if echo "$content" | grep -q "targets-path $path_target"; then
      seen_objs+="$obj,"
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      echo "[stale] ${title:-$filepath} ($kind) — blob changed since note was written"
      echo "$content"
      echo ""
    fi
  done

  # 3. Walk parent directories for tree notes (exact + stale)
  local dir="$filepath"
  while true; do
    dir=$(dirname "$dir")
    local tree
    if [[ "$dir" == "." ]]; then
      tree=$(git rev-parse "$at^{tree}" 2>/dev/null || true)
    else
      tree=$(git rev-parse "$at:$dir" 2>/dev/null || true)
    fi
    local dir_label="${dir}"
    [[ "$dir" == "." ]] && dir_label="(root)"

    if [[ -n "$tree" ]]; then
      # Exact match
      local note
      note=$(git notes --ref="$REF" show "$tree" 2>/dev/null || true)
      if [[ -n "$note" ]]; then
        local kind=$(note_header "$note" "kind")
        local title=$(note_header "$note" "title")
        echo "[tree] ${title:-$dir_label} ($kind) — inherited"
        echo "$note"
        echo ""
      fi
    fi

    # Stale tree notes: target this dir path but on an older tree OID
    local treepath_target
    [[ "$dir" == "." ]] && treepath_target="treepath:." || treepath_target="treepath:$dir"
    git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
      [[ "$obj" == "${tree:-}" ]] && continue
      local content
      content=$(git cat-file -p "$noteblob")
      if echo "$content" | grep -q "targets-treepath $treepath_target\$"; then
        local kind=$(note_header "$content" "kind")
        local title=$(note_header "$content" "title")
        echo "[stale-tree] ${title:-$dir_label} ($kind) — tree changed since note was written"
        echo "$content"
        echo ""
      fi
    done

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

}

cmd_follow() {
  local target="${1:-HEAD}"
  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  # Read the note on this object
  local note
  note=$(git notes --ref="$REF" show "$oid" 2>/dev/null || true)
  if [[ -z "$note" ]]; then
    echo "(no mycelium note on $type:${oid:0:12})"
    return
  fi

  local kind=$(note_header "$note" "kind")
  local title=$(note_header "$note" "title")
  if [[ -n "$filepath" ]]; then
    echo "=== $type:${oid:0:12} ($filepath) [$kind] ${title:-} ==="
  else
    echo "=== $type:${oid:0:12} [$kind] ${title:-} ==="
  fi
  echo "$note"
  echo ""

  # Extract and resolve each edge target
  local edge_lines
  edge_lines=$(echo "$note" | grep '^edge ' || true)
  [[ -z "$edge_lines" ]] && return

  echo "--- edges ---"
  echo "$edge_lines" | while IFS= read -r edge_line; do
    local edge_type edge_target
    edge_type=$(echo "$edge_line" | awk '{print $2}')
    edge_target=$(echo "$edge_line" | awk '{print $3}')
    local target_type target_ref
    target_type=${edge_target%%:*}
    target_ref=${edge_target#*:}

    # Resolve: is there a note on the target?
    case "$target_type" in
      path|treepath)
        # Resolve path to current blob/tree
        local resolved_oid
        resolved_oid=$(git rev-parse "HEAD:$target_ref" 2>/dev/null || true)
        if [[ -n "$resolved_oid" ]]; then
          local target_note
          target_note=$(git notes --ref="$REF" show "$resolved_oid" 2>/dev/null || true)
          if [[ -n "$target_note" ]]; then
            local t_kind=$(note_header "$target_note" "kind")
            local t_title=$(note_header "$target_note" "title")
            echo "  $edge_type → $edge_target [$t_kind] ${t_title:-}"
          else
            echo "  $edge_type → $edge_target (no note)"
          fi
        else
          echo "  $edge_type → $edge_target (cannot resolve)"
        fi
        ;;
      blob|tree|commit|tag|note)
        local target_note
        target_note=$(git notes --ref="$REF" show "$target_ref" 2>/dev/null || true)
        if [[ -n "$target_note" ]]; then
          local t_kind=$(note_header "$target_note" "kind")
          local t_title=$(note_header "$target_note" "title")
          echo "  $edge_type → $target_type:${target_ref:0:12} [$t_kind] ${t_title:-}"
        else
          echo "  $edge_type → $target_type:${target_ref:0:12} (no note)"
        fi
        ;;
      *)
        echo "  $edge_type → $edge_target"
        ;;
    esac
  done
}

cmd_refs() {
  local target="${1:-HEAD}"
  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  if [[ -n "$filepath" ]]; then
    echo "=== notes referencing: $filepath ($type:${oid:0:12}) ==="
  else
    echo "=== notes referencing: $type:${oid:0:12} ==="
  fi
  echo ""

  local found=false
  git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
    local content
    content=$(git cat-file -p "$noteblob")
    local match=false

    # Match by OID (exact or prefix in edge targets)
    if echo "$content" | grep -q "^edge .* .*:$oid"; then
      match=true
    fi

    # Match by path if target is a file/dir
    if [[ -n "$filepath" ]] && echo "$content" | grep -q "^edge .* path:$filepath\$"; then
      match=true
    fi
    if [[ -n "$filepath" ]] && echo "$content" | grep -q "^edge .* treepath:$filepath\$"; then
      match=true
    fi

    if [[ "$match" == "true" ]]; then
      local label=$(obj_label "$obj")
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      local edges
      edges=$(echo "$content" | grep "^edge .* .*:$oid\|^edge .* path:${filepath:-__NOMATCH__}\|^edge .* treepath:${filepath:-__NOMATCH__}" || true)
      echo "$label [$kind] ${title:-}"
      echo "$edges" | sed 's/^/  /'
      echo ""
    fi
  done
}

cmd_kinds() {
  echo "Kinds in use:"
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    git cat-file -p "$blob" | grep "^kind " | cut -d' ' -f2
  done | sort | uniq -c | sort -rn | while read count kind; do
    printf "  %-20s %s note(s)\n" "$kind" "$count"
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

cmd_branch() {
  local subcmd="${1:-}"
  case "$subcmd" in
    "")
      echo "current: $REF (refs/notes/$REF)"
      echo ""
      echo "all notes refs:"
      git for-each-ref --format='  %(refname:short)' refs/notes/ 2>/dev/null
      ;;
    use)
      local name="${2:?usage: mycelium branch use <name>}"
      if [[ "$name" == "main" || "$name" == "default" ]]; then
        rm -f "$_git_dir/mycelium-branch"
        echo "Switched to default ref: refs/notes/mycelium"
      else
        # Can't nest under refs/notes/mycelium/ — git refs can't be
        # both a leaf and a directory. Use dash separator instead.
        echo "mycelium--$name" > "$_git_dir/mycelium-branch"
        echo "Switched to branch ref: refs/notes/mycelium--$name"
      fi
      ;;
    merge)
      local name="${2:?usage: mycelium branch merge <name>}"
      local source_ref="mycelium--$name"
      local source_count
      source_count=$(git notes --ref="$source_ref" list 2>/dev/null | wc -l)
      if [[ "$source_count" -eq 0 ]]; then
        echo "No notes in refs/notes/$source_ref"
        return 1
      fi
      echo "Merging $source_count note(s) from $source_ref into $REF..."
      git notes --ref="$REF" merge --strategy=cat_sort_uniq "$source_ref"
      echo "Done. Notes from $source_ref are now in $REF."
      ;;
    *)
      cat <<'EOF'
mycelium branch                      Show current ref and all notes refs
mycelium branch use <name>           Print export command for branch-scoped notes
mycelium branch merge <name>         Merge branch notes into current ref

Workflow:
  mycelium.sh branch use jj-support            # switch to branch ref
  mycelium.sh note HEAD -k decision -m "..."  # notes go to branch ref
  mycelium.sh branch use main                 # switch back
  mycelium.sh branch merge jj-support         # merge when ready
EOF
      ;;
  esac
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
  follow)     shift; cmd_follow "$@" ;;
  refs)       shift; cmd_refs "$@" ;;
  context)    shift; cmd_context "$@" ;;
  edges)      shift; cmd_edges "$@" ;;
  find)       shift; cmd_find "$@" ;;
  kinds)      cmd_kinds ;;
  log)        shift; cmd_log "$@" ;;
  list)       cmd_list ;;
  branch)     shift; cmd_branch "$@" ;;
  activate)   cmd_activate ;;
  sync-init)  shift; cmd_sync_init "$@" ;;
  dump)       cmd_dump ;;
  help|*)     usage ;;
esac
