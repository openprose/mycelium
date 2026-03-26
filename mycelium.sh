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
  echo "$1" | grep "^$2 " | head -1 | sed "s/^$2 //" || true
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
  mycelium compost [path|.] [--dry-run|--report|--compost|--renew]  Triage stale notes
  mycelium doctor                                 Check consistency
  mycelium branch [use|merge] [name]              Branch-scoped notes
  mycelium prime                                   Output skill + live repo context
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

  # jj-specific help when colocated
  if [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; then
    cat <<'EOF'

jj+git colocated repo detected:
  - Commit notes auto-add a targets-change edge (stable across rewrites)
  - read/follow fall back to change_id lookup when commit OID changes
  - Prefer notes on blobs/paths (stable) over commits (rewritten by jj)
  - jj log doesn't show notes — use: mycelium.sh log
EOF
  fi
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
      # jj colocated: add stable change_id edge (survives rewrites)
      if [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; then
        local _cid
        _cid=$(jj log -r "$oid" --no-graph -T 'change_id' 2>/dev/null || true)
        [[ -n "$_cid" ]] && auto_edges+=("targets-change change:$_cid")
      fi
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
      # Show what's being overwritten — backpressure against accidental clobber
      local existing_content
      existing_content=$(git cat-file -p "$existing_blob")
      local existing_kind=$(note_header "$existing_content" "kind")
      local existing_title=$(note_header "$existing_content" "title")
      echo "⚠ overwriting [$existing_kind] \"${existing_title:-(untitled)}\" on ${type}:${oid:0:12}" >&2
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

  # Show what was written and its stability
  echo "$oid"
  if [[ "$type" == "blob" && -n "$filepath" ]]; then
    echo "  (via path:$filepath — findable if file changes)" >&2
  elif [[ "$type" == "blob" ]]; then
    echo "  (pinned to blob:${oid:0:12} — specific to this version)" >&2
  elif [[ "$type" == "tree" && "${filepath:-}" == "." ]]; then
    echo "  (project-level — always findable via context)" >&2
  elif [[ "$type" == "tree" && -n "$filepath" ]]; then
    echo "  (via treepath:$filepath — findable if dir changes)" >&2
  elif [[ "$type" == "commit" ]]; then
    local _has_change=""
    for e in "${auto_edges[@]}" "${edges[@]}"; do
      case "$e" in targets-change*) _has_change=yes ;; esac
    done
    if [[ -n "$_has_change" ]]; then
      echo "  (commit + change_id — survives jj rewrites)" >&2
    else
      echo "  (commit — pinned to this OID)" >&2
    fi
  fi
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

  # jj fallback: look up by change_id edge
  if [[ "$type" == "commit" ]] && { [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; }; then
    local _cid
    _cid=$(jj log -r "$oid" --no-graph -T 'change_id' 2>/dev/null || true)
    if [[ -n "$_cid" ]]; then
      local _found=""
      local notelist
      notelist=$(git notes --ref="$REF" list 2>/dev/null || true)
      while read noteblob obj; do
        [[ -z "$noteblob" ]] && continue
        local content
        content=$(git cat-file -p "$noteblob")
        if echo "$content" | awk -v cid="$_cid" '/^edge targets-change change:/ && index($0, cid) {found=1; exit} END {exit !found}'; then
          local kind=$(note_header "$content" "kind")
          local title=$(note_header "$content" "title")
          echo "[via change_id] ${title:-(untitled)} ($kind)"
          echo "$content"
          _found=yes
          break
        fi
      done <<< "$notelist"
      [[ -n "$_found" ]] && return
    fi
  fi

  echo "(no mycelium note)"
}

cmd_context() {
  local filepath="" at="HEAD" show_all=false

  # Parse args
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all) show_all=true; shift ;;
      *)     if [[ -z "$filepath" ]]; then filepath="$1"; else at="$1"; fi; shift ;;
    esac
  done
  [[ -z "$filepath" ]] && { echo "Usage: mycelium context <path> [ref] [--all]" >&2; exit 1; }

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
      local note_status=$(note_header "$note" "status")
      if [[ "$note_status" == "composted" && "$show_all" == "false" ]]; then
        : # skip
      else
        echo "[exact] ${title:-$filepath} ($kind)"
        echo "$note"
        echo ""
      fi
    fi
  fi

  # 2. Stale/contextual: notes that target this path but are on a different blob
  local path_target="path:$filepath"
  local stale_count=0
  local seen_objs="${blob:-},"
  git notes --ref="$REF" list 2>/dev/null | while read noteblob obj; do
    [[ "$obj" == "${blob:-}" ]] && continue
    local content
    content=$(git cat-file -p "$noteblob")
    if echo "$content" | grep -q "targets-path $path_target"; then
      seen_objs+="$obj,"
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      local note_status=$(note_header "$content" "status")

      # Hide composted unless --all
      if [[ "$note_status" == "composted" && "$show_all" == "false" ]]; then
        continue
      fi

      # Stale notes: one-liner summary (full content with --all)
      if [[ "$show_all" == "true" ]]; then
        echo "[stale] ${title:-$filepath} ($kind) — blob changed since note was written"
        echo "$content"
        echo ""
      else
        echo "[stale] ${title:-$filepath} ($kind) — use 'read ${obj:0:12}' for full note"
      fi
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
        local note_status=$(note_header "$note" "status")
        if [[ "$note_status" == "composted" && "$show_all" == "false" ]]; then
          : # skip
        else
          echo "[tree] ${title:-$dir_label} ($kind) — inherited"
          echo "$note"
          echo ""
        fi
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
        local note_status=$(note_header "$content" "status")

        if [[ "$note_status" == "composted" && "$show_all" == "false" ]]; then
          continue
        fi

        if [[ "$show_all" == "true" ]]; then
          echo "[stale-tree] ${title:-$dir_label} ($kind) — tree changed since note was written"
          echo "$content"
          echo ""
        else
          echo "[stale-tree] ${title:-$dir_label} ($kind) — use 'read ${obj:0:12}' for full note"
        fi
      fi
    done

    [[ "$dir" == "." || "$dir" == "/" ]] && break
  done

  # 4. Note on the commit
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
      local notelist
      notelist=$(git notes --ref="$source_ref" list 2>/dev/null || true)
      if [[ -z "$notelist" ]]; then
        echo "No notes in refs/notes/$source_ref"
        return 1
      fi
      local count=0
      while read noteblob obj; do
        local existing
        existing=$(git notes --ref="$REF" list "$obj" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$existing" ]]; then
          # Object has notes in both refs — branch supersedes main
          local branch_content
          branch_content=$(git cat-file -p "$noteblob")
          # Prepend supersedes header pointing to main's note blob
          local merged="$(echo "$branch_content" | awk '/^kind /{print; next} /^title /{print; next} !done{print "supersedes '"$existing"'"; done=1} {print}')"
          git notes --ref="$REF" add -f -m "$merged" "$obj"
        else
          # Object only in branch — copy directly
          git notes --ref="$REF" add -f -C "$noteblob" "$obj"
        fi
        count=$((count + 1))
      done <<< "$notelist"
      echo "Merged $count note(s) from $source_ref into $REF."
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

cmd_doctor() {
  # White hat: facts only. What exists, in what state.

  local tmp
  tmp=$(mktemp)

  # Classify each note — avoid grep (exits 1 on no match + pipefail)
  local notelist
  notelist=$(git notes --ref="$REF" list 2>/dev/null || true)
  [[ -z "$notelist" ]] && { echo "notes  0"; rm -f "$tmp"; return; }

  while read noteblob obj; do
    local content kind status note_status target_path target_treepath n_edges
    content=$(git cat-file -p "$noteblob")
    kind=$(echo "$content" | awk '/^kind /{print $2; exit}')
    note_status=$(echo "$content" | awk '/^status /{print $2; exit}')
    status="current"

    # Composted notes are composted regardless of staleness
    if [[ "$note_status" == "composted" ]]; then
      status="composted"
      n_edges=$(echo "$content" | awk '/^edge /{n++} END{print n+0}')
      echo "$kind $status $n_edges"
      continue
    fi

    target_path=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
    target_treepath=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')

    if [[ -n "$target_path" ]]; then
      local current_blob
      current_blob=$(git rev-parse "HEAD:$target_path" 2>/dev/null || true)
      if [[ -z "$current_blob" ]]; then status="orphaned"
      elif [[ "$current_blob" != "$obj" ]]; then status="stale"
      fi
    elif [[ -n "$target_treepath" ]]; then
      if [[ "$target_treepath" == "." ]]; then
        # Root tree notes are project-level — always "current" in meaning.
        # The tree OID changes every commit but the note's intent doesn't.
        status="current"
      else
        local current_tree
        current_tree=$(git rev-parse "HEAD:$target_treepath" 2>/dev/null || true)
        if [[ -z "$current_tree" ]]; then status="orphaned"
        elif [[ "$current_tree" != "$obj" ]]; then status="stale"
        fi
      fi
    else
      git cat-file -t "$obj" &>/dev/null || status="orphaned"
    fi

    n_edges=$(echo "$content" | awk '/^edge /{n++} END{print n+0}')
    echo "$kind $status $n_edges"
  done <<< "$notelist" > "$tmp"

  # Summarize
  read total n_current n_stale n_orphaned n_composted n_edges < <(
    awk '
      { total++; edges+=$3 }
      $2=="current"   { current++ }
      $2=="stale"     { stale++ }
      $2=="orphaned"  { orphaned++ }
      $2=="composted" { composted++ }
      END { print total+0, current+0, stale+0, orphaned+0, composted+0, edges+0 }
    ' "$tmp"
  )

  echo "notes  $total  (current:$n_current stale:$n_stale composted:$n_composted orphaned:$n_orphaned)"
  echo "edges  $n_edges"
  printf "kinds  "
  awk '{print $1}' "$tmp" | sort | uniq -c | sort -rn | \
    awk '{printf "%s:%s ", $2, $1}'
  echo ""

  # jj: report colocated status
  if [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; then
    local jj_ver
    jj_ver=$(jj version 2>/dev/null | head -1 || echo "unknown")
    echo "jj     colocated ($jj_ver)"
  fi

  rm -f "$tmp"
}

# --- compost helpers (shared by direct + interactive paths) ---

# Mark a note as composted by OID
_compost_note() {
  local obj="$1"
  local content
  content=$(git notes --ref="$REF" show "$obj" 2>/dev/null || true)
  [[ -z "$content" ]] && { echo "Error: no note on $obj" >&2; return 1; }

  local new_content
  if echo "$content" | grep -q '^status '; then
    new_content=$(echo "$content" | sed 's/^status .*/status composted/')
  else
    new_content=$(echo "$content" | awk '/^kind /{print; print "status composted"; next} {print}')
  fi
  git notes --ref="$REF" add -f -m "$new_content" "$obj"
}

# Re-attach a note to the current blob/tree at its path
_renew_note() {
  local obj="$1"
  local content
  content=$(git notes --ref="$REF" show "$obj" 2>/dev/null || true)
  [[ -z "$content" ]] && { echo "Error: no note on $obj" >&2; return 1; }

  # Find the path this note targets
  local note_path
  note_path=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
  [[ -z "$note_path" ]] && note_path=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')
  [[ -z "$note_path" ]] && { echo "Error: note has no path edge, cannot renew" >&2; return 1; }

  local current_oid
  current_oid=$(git rev-parse "HEAD:$note_path" 2>/dev/null || true)
  [[ -z "$current_oid" ]] && { echo "Error: path no longer exists: $note_path" >&2; return 1; }

  local current_type
  current_type=$(git cat-file -t "$current_oid" 2>/dev/null)

  # Check if new object already has a note
  local existing_on_new
  existing_on_new=$(git notes --ref="$REF" list "$current_oid" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -n "$existing_on_new" ]]; then
    echo "Error: current version already has a note" >&2
    return 1
  fi

  # Update applies-to edge and write on new object
  local new_content
  new_content=$(echo "$content" | sed "s|^edge applies-to [a-z]*:.*|edge applies-to $current_type:$current_oid|")
  git notes --ref="$REF" add -f -m "$new_content" "$current_oid"

  # Compost the old one
  _compost_note "$obj"
  echo "$current_oid"
}

# Collect stale notes, optionally filtered by path
_collect_stale() {
  local target="${1:-.}"
  local notelist
  notelist=$(git notes --ref="$REF" list 2>/dev/null || true)
  [[ -z "$notelist" ]] && return

  while read noteblob obj; do
    local content
    content=$(git cat-file -p "$noteblob")

    local note_status
    note_status=$(note_header "$content" "status")
    [[ "$note_status" == "composted" ]] && continue

    local target_path target_treepath
    target_path=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
    target_treepath=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')

    local is_stale=false note_target=""

    if [[ -n "$target_path" ]]; then
      note_target="$target_path"
      local current_blob
      current_blob=$(git rev-parse "HEAD:$target_path" 2>/dev/null || true)
      if [[ -z "$current_blob" ]]; then
        is_stale=true
      elif [[ "$current_blob" != "$obj" ]]; then
        is_stale=true
      fi
    elif [[ -n "$target_treepath" && "$target_treepath" != "." ]]; then
      note_target="$target_treepath"
      local current_tree
      current_tree=$(git rev-parse "HEAD:$target_treepath" 2>/dev/null || true)
      if [[ -z "$current_tree" ]]; then
        is_stale=true
      elif [[ "$current_tree" != "$obj" ]]; then
        is_stale=true
      fi
    fi

    if [[ "$is_stale" == "true" ]]; then
      if [[ "$target" != "." ]]; then
        case "$note_target" in
          "$target"|"$target"/*) ;;
          *) continue ;;
        esac
      fi
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      # Output: obj\tpath\tkind\ttitle
      printf '%s\t%s\t%s\t%s\n' "$obj" "$note_target" "$kind" "${title:-(untitled)}"
    fi
  done <<< "$notelist"
}

cmd_compost() {
  local target="" action="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)   dry_run=true; shift ;;
      --report)    action="report"; shift ;;
      --compost)   action="compost"; shift ;;
      --renew)     action="renew"; shift ;;
      -*)          echo "Unknown option: $1" >&2; exit 1 ;;
      *)           target="$1"; shift ;;
    esac
  done
  target="${target:-.}"

  # Direct action (agent-native)
  if [[ "$action" == "compost" && "$target" != "." ]]; then
    # Is target an OID? (hex string, 6+ chars)
    if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
      # Resolve short OID to full — check if it's a noted object
      local full_oid
      full_oid=$(git notes --ref="$REF" list 2>/dev/null | awk -v t="$target" '$2 ~ "^"t {print $2; exit}')
      [[ -z "$full_oid" ]] && { echo "Error: no note on object matching $target" >&2; exit 1; }
      _compost_note "$full_oid"
      local content title kind
      content=$(git notes --ref="$REF" show "$full_oid" 2>/dev/null || true)
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      echo "✓ composted [$kind] ${title:-(untitled)}"
      return
    fi
    # Path: batch compost all stale notes on this path
    local found=false
    while IFS=$'\t' read -r obj note_path kind title; do
      _compost_note "$obj"
      echo "✓ composted [$kind] $title — $note_path"
      found=true
    done < <(_collect_stale "$target")
    if [[ "$found" == "false" ]]; then
      echo "No stale notes under $target"
    fi
    return
  fi

  if [[ "$action" == "renew" && "$target" != "." ]]; then
    # Is target an OID?
    if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
      local full_oid
      full_oid=$(git notes --ref="$REF" list 2>/dev/null | awk -v t="$target" '$2 ~ "^"t {print $2; exit}')
      [[ -z "$full_oid" ]] && { echo "Error: no note on object matching $target" >&2; exit 1; }
      local new_oid
      new_oid=$(_renew_note "$full_oid") || exit 1
      local content title kind
      content=$(git notes --ref="$REF" show "$new_oid" 2>/dev/null || true)
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      echo "✓ renewed [$kind] ${title:-(untitled)} → ${new_oid:0:12}"
      return
    fi
    # Path: batch renew all stale notes on this path
    local found=false
    while IFS=$'\t' read -r obj note_path kind title; do
      local new_oid
      new_oid=$(_renew_note "$obj") && {
        echo "✓ renewed [$kind] $title — $note_path → ${new_oid:0:12}"
        found=true
      }
    done < <(_collect_stale "$target")
    if [[ "$found" == "false" ]]; then
      echo "No stale notes under $target"
    fi
    return
  fi

  # Report mode
  if [[ "$action" == "report" ]]; then
    local stale_count=0 composted_count=0
    local notelist
    notelist=$(git notes --ref="$REF" list 2>/dev/null || true)
    [[ -z "$notelist" ]] && { echo "mycelium: 0 stale, 0 composted"; return; }
    while read noteblob obj; do
      local content
      content=$(git cat-file -p "$noteblob")
      local ns
      ns=$(note_header "$content" "status")
      if [[ "$ns" == "composted" ]]; then
        composted_count=$((composted_count + 1))
      else
        # Check if stale
        local tp
        tp=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
        if [[ -n "$tp" ]]; then
          local cb
          cb=$(git rev-parse "HEAD:$tp" 2>/dev/null || true)
          if [[ -n "$cb" && "$cb" != "$obj" ]] || [[ -z "$cb" ]]; then
            stale_count=$((stale_count + 1))
          fi
        fi
      fi
    done <<< "$notelist"
    echo "mycelium: $stale_count stale, $composted_count composted"
    return
  fi

  # List / interactive mode
  local stale_lines
  stale_lines=$(_collect_stale "$target")
  local stale_count
  if [[ -z "$stale_lines" ]]; then
    echo "No stale notes${target:+ under $target}."
    return
  fi
  stale_count=$(echo "$stale_lines" | wc -l)

  echo "$stale_count stale note(s)${target:+ under $target}:"
  echo ""

  while IFS=$'\t' read -r obj note_path kind title; do
    echo "  [$kind] ${title} — $note_path (${obj:0:12})"

    [[ "$dry_run" == "true" ]] && continue

    # Interactive: show note and ask
    local content
    content=$(git notes --ref="$REF" show "$obj" 2>/dev/null)
    echo ""
    echo "$content" | sed 's/^/    /'
    echo ""
    echo "  (c)ompost  — mark as composted, hide from context"
    echo "  (r)enew    — re-attach to current version"
    echo "  (s)kip     — leave as-is"
    echo "  (q)uit     — stop composting"

    local choice
    while true; do
      if [[ -t 0 ]]; then
        read -r -p "  [c/r/s/q] " choice </dev/tty
      else
        read -r choice || choice="q"
      fi
      case "$choice" in
        c|compost)
          _compost_note "$obj"
          echo "  ✓ composted"
          echo ""
          break ;;
        r|renew)
          local new_oid
          new_oid=$(_renew_note "$obj") && echo "  ✓ renewed → ${new_oid:0:12}" || true
          echo ""
          break ;;
        s|skip)
          echo "  — skipped"
          echo ""
          break ;;
        q|quit)
          echo "  — stopping"
          return ;;
        *)
          echo "  ? c/r/s/q" ;;
      esac
    done
  done <<< "$stale_lines"
}

cmd_dump() {
  git notes --ref="$REF" list 2>/dev/null | while read blob obj; do
    local label=$(obj_label "$obj")
    echo "=== $label ==="
    git cat-file -p "$blob"
    echo
  done
}

cmd_prime() {
  # Find SKILL.md: same directory as this script, or repo root
  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd)
  local skill=""
  if [[ -f "$script_dir/SKILL.md" ]]; then
    skill="$script_dir/SKILL.md"
  else
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$repo_root" && -f "$repo_root/SKILL.md" ]] && skill="$repo_root/SKILL.md"
  fi

  # 1. Skill content (strip YAML frontmatter)
  if [[ -n "$skill" ]]; then
    awk 'BEGIN{fm=0} /^---$/{fm++; next} fm>=2||fm==0{print}' "$skill"
  else
    # No SKILL.md — emit minimal inline skill
    cat <<'SKILL'
# Mycelium

Structured notes attached to git objects via `refs/notes/mycelium`.

**Before working on a file, check for its note. After meaningful work, leave a note.**

```bash
mycelium.sh context <path>       # all notes relevant to a file
mycelium.sh read [target]        # read a single note
mycelium.sh note <target> -k <kind> -m <body>  # write a note
mycelium.sh find <kind>          # find all notes of a kind
mycelium.sh compost [path|.]     # triage stale notes
mycelium.sh doctor               # graph state
```
SKILL
  fi

  # 2. Live repo state
  local notelist
  notelist=$(git notes --ref="$REF" list 2>/dev/null || true)
  if [[ -z "$notelist" ]]; then
    echo ""
    echo "---"
    echo "No mycelium notes in this repo yet."
    return
  fi

  echo ""
  echo "---"
  echo "## This repo"
  echo ""
  echo '```'
  cmd_doctor
  cmd_compost --report
  echo '```'

  # 3. Root tree notes (project-level constraints, values, warnings)
  local root_tree
  root_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  if [[ -n "$root_tree" ]]; then
    local root_note
    root_note=$(git notes --ref="$REF" show "$root_tree" 2>/dev/null || true)
    if [[ -n "$root_note" ]]; then
      echo ""
      echo "### Project notes"
      echo ""
      echo "$root_note"
    fi
  fi

  # Stale root tree notes (values, constraints from earlier commits)
  while read noteblob obj; do
    [[ "$obj" == "${root_tree:-}" ]] && continue
    local content
    content=$(git cat-file -p "$noteblob")
    local note_status
    note_status=$(note_header "$content" "status")
    [[ "$note_status" == "composted" ]] && continue
    if echo "$content" | grep -q "^edge targets-treepath treepath:\.\$"; then
      local kind=$(note_header "$content" "kind")
      local title=$(note_header "$content" "title")
      echo ""
      echo "### ${title:-(untitled)} ($kind)"
      echo ""
      echo "$content"
    fi
  done <<< "$notelist"
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
  compost)    shift; cmd_compost "$@" ;;
  doctor)     cmd_doctor ;;
  dump)       cmd_dump ;;
  prime)      cmd_prime ;;
  help|*)     usage ;;
esac
