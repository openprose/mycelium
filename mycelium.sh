#!/usr/bin/env bash
# mycelium — git-native note graph
# No dependencies beyond git and bash.
# Version: derived from git tags at runtime. Installer stamps non-git copies.
# Resolve symlinks with POSIX-only tools (portable to Linux, macOS, Git Bash).
_mycelium_f="$0"
while [ -L "$_mycelium_f" ]; do
  _mycelium_d="$(cd "$(dirname "$_mycelium_f")" && pwd)"
  _mycelium_f="$(ls -l "$_mycelium_f" | awk '{print $NF}')"
  case "$_mycelium_f" in /*) ;; *) _mycelium_f="$_mycelium_d/$_mycelium_f" ;; esac
done
MYCELIUM_VERSION=$(git -C "$(dirname "$_mycelium_f")" describe --tags --always 2>/dev/null || echo "__MYCELIUM_UNSTAMPED__")
unset _mycelium_f _mycelium_d
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

# --- slot helpers ---

_RESERVED_SLOTS="main|default"

_slot_ref() {
  local slot="${1:-}"
  if [[ -z "$slot" ]]; then
    echo "$REF"
  else
    echo "${REF}--slot--${slot}"
  fi
}

_validate_slot() {
  local slot="$1"
  [[ -z "$slot" ]] && return 0
  if echo "$slot" | grep -qE "^(${_RESERVED_SLOTS})$"; then
    echo "Error: '$slot' is a reserved slot name" >&2
    return 1
  fi
  if echo "$slot" | grep -q -- '--slot--'; then
    echo "Error: slot name cannot contain '--slot--'" >&2
    return 1
  fi
  if ! git check-ref-format "refs/notes/test--slot--$slot" 2>/dev/null; then
    echo "Error: '$slot' is not a valid slot name" >&2
    return 1
  fi
  return 0
}

_validate_branch_name() {
  local name="$1"
  # After prepending "mycelium--", names like "import--foo" become "mycelium--import--foo"
  # which collides with the import/export/slot ref namespaces.
  if echo "$name" | grep -qE -- '--(slot|import|export)--|^(slot|import|export)--'; then
    echo "Error: branch name cannot contain reserved namespace separators (--slot--, --import--, --export--)" >&2
    return 1
  fi
}

_assert_writable_ref() {
  local ref="$1"
  if [[ "$ref" == *"--import--"* ]]; then
    echo "Error: import refs are read-only. These are snapshots from a foreign repo." >&2
    return 1
  fi
  if [[ "$ref" == *"--export--"* ]]; then
    echo "Error: export refs are read-only. Use 'mycelium.sh export' to publish notes." >&2
    return 1
  fi
}

_import_refs() {
  git for-each-ref --format='%(refname:short)' "refs/notes/${REF}--import--*" 2>/dev/null | \
    grep -v -- '--import--_discovering$' | sed 's|^notes/||' | sort -u
}

_import_name_from_ref() {
  echo "$1" | sed 's/.*--import--//'
}

_all_slot_refs() {
  echo "$REF"
  git for-each-ref --format='%(refname:short)' "refs/notes/${REF}--slot--*" 2>/dev/null | \
    sed 's|^notes/||' | sort -u
}

# mode=exact      -> current base ref only unless --slot given
# mode=aggregate  -> current base ref + all slot refs unless --slot given
_each_ref() {
  local mode="$1" slot="${2:-}"
  if [[ -n "$slot" ]]; then
    _validate_slot "$slot" || return 1
    _slot_ref "$slot"
    return
  fi

  echo "$REF"
  [[ "$mode" == "aggregate" ]] || return 0
  git for-each-ref --format='%(refname:short)' "refs/notes/${REF}--slot--*" 2>/dev/null | \
    sed 's|^notes/||' | sort -u
}

_slot_name_from_ref() {
  local ref="$1"
  if echo "$ref" | grep -q -- '--slot--'; then
    echo "$ref" | sed 's/.*--slot--//'
  else
    echo "default"
  fi
}

_slot_prefix() {
  local ref="$1"
  local name
  name=$(_slot_name_from_ref "$ref")
  echo "[slot:$name]"
}

_slot_display() {
  local ref="$1"
  local name
  name=$(_slot_name_from_ref "$ref")
  if [[ "$name" != "default" ]]; then
    echo "[slot:$name] "
  fi
}

_all_notes() {
  while read -r sref; do
    git notes --ref="$sref" list 2>/dev/null | while read -r noteblob obj; do
      [[ -z "$noteblob" ]] && continue
      echo "$sref $noteblob $obj"
    done
  done < <(_all_slot_refs)
}


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
  mycelium find <kind>                            Find all notes of a kind
  mycelium kinds                                  List all kinds in use
  mycelium edges [type]                           List all edges
  mycelium list                                   List all annotated objects
  mycelium log [n]                                Recent commits with notes
  mycelium dump                                   All notes, greppable
  mycelium compost [path|oid] [--compost|--renew|--dry-run|--report]
  mycelium doctor                                 Check consistency
  mycelium prime                                  Skill + live repo context
  mycelium branch [use|merge] [name]              Branch-scoped notes
  mycelium activate                               Show notes in git log
  mycelium repo-id [init]                          Durable repository identity
  mycelium zone [init [level]]                     Confidentiality zone (default: 80)
  mycelium export <target> --audience <a>           Export note to audience ref
  mycelium import <remote> [--as <name>] [--refresh] Import notes from remote
  mycelium sync-init [remote]                      Configure fetch/push
  mycelium sync-init --export-only [remote]        Configure export ref sync only

Targets: HEAD (default), commit ref, file path, directory path, OID.
Auto-edges: commit→explains, blob→applies-to+targets-path, tree→applies-to+targets-treepath.

Options for 'note':
  -k, --kind <kind>         Required. Any string. Common: decision, context, summary,
                           warning, constraint, observation, value — or invent your own
  -e, --edge <type target>  Extra edges (auto-edges are always added)
  -t, --title <title>       Short label
  -s, --status <status>     active (default)|archived
  --slot <name>             Write to a named slot (default: shared lane)
  -f, --force               Overwrite existing note (required if target already has one)
  -m, --message <body>      Note body (reads stdin if omitted and not a tty)

Workflow scripts shipped with this repo (not core CLI):
  scripts/context-workflow.sh <path> [ref]  Recommended arrival workflow
  scripts/path-history.sh <path> [ref]      Historical notes for a file path
  scripts/note-history.sh <target>          Git-native note overwrite history

Slots:
  Multiple notes on the same object via named slots. Each slot is an
  independent notes ref. read/follow use default slot; find/
  doctor/prime aggregate all slots. --slot works on note, read, follow.
  Reserved names: main, default.
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
  local target="" kind="" title="" status="" body="" slot="" force=false
  local -a edges=()

  # Parse args — target is the first non-flag argument, or HEAD
  while [[ $# -gt 0 ]]; do
    case $1 in
      -k|--kind)       kind="$2"; shift 2 ;;
      -e|--edge)       edges+=("$2"); shift 2 ;;
      -t|--title)      title="$2"; shift 2 ;;
      -s|--status)     status="$2"; shift 2 ;;
      --slot)          slot="$2"; shift 2 ;;
      -f|--force)      force=true; shift ;;
      -m|--message)    body="$2"; shift 2 ;;
      -*)              echo "Unknown option: $1" >&2; exit 1 ;;
      *)               target="$1"; shift ;;
    esac
  done

  target="${target:-HEAD}"
  [[ -z "$kind" ]] && { echo "Error: --kind is required" >&2; exit 1; }

  # Validate and resolve slot ref
  _validate_slot "$slot" || exit 1
  local WRITE_REF
  WRITE_REF=$(_slot_ref "$slot")
  _assert_writable_ref "$WRITE_REF" || exit 1

  # Also check the base REF (set via MYCELIUM_REF env or branch file)
  _assert_writable_ref "$REF" || exit 1

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

  # Guard against silent overwrite
  local existing_blob
  existing_blob=$(git notes --ref="$WRITE_REF" list "$oid" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -n "$existing_blob" ]]; then
    local existing_content
    existing_content=$(git cat-file -p "$existing_blob")
    local existing_kind existing_title slot_label
    existing_kind=$(note_header "$existing_content" "kind")
    existing_title=$(note_header "$existing_content" "title")
    slot_label="${slot:+[slot:$slot] }"
    if [[ "$force" != "true" ]]; then
      echo "Error: ${slot_label}[$existing_kind] \"${existing_title:-(untitled)}\" already exists on ${type}:${oid:0:12}" >&2
      echo "  Use -f to overwrite, or choose a different target." >&2
      exit 1
    fi
    echo "⚠ ${slot_label}overwriting [$existing_kind] \"${existing_title:-(untitled)}\" on ${type}:${oid:0:12}" >&2
  fi

  # Build note content
  local content="kind $kind"
  [[ -n "$title" ]]      && content+=$'\n'"title $title"
  [[ -n "$status" ]]     && content+=$'\n'"status $status"
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

  git notes --ref="$WRITE_REF" add -f -m "$content" "$oid" 2>/dev/null

  # Show what was written and its stability
  echo "$oid"
  if [[ "$type" == "blob" && -n "$filepath" ]]; then
    echo "  (via path:$filepath — findable if file changes)" >&2
  elif [[ "$type" == "blob" ]]; then
    echo "  (pinned to blob:${oid:0:12} — specific to this version)" >&2
  elif [[ "$type" == "tree" && "${filepath:-}" == "." ]]; then
    echo "  (project-level — stable root-tree target)" >&2
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
  local target="" slot=""
  # Parse args
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      target="$1"; shift ;;
    esac
  done
  target="${target:-HEAD}"
  _validate_slot "$slot" || exit 1

  local READ_REF
  READ_REF=$(_slot_ref "$slot")

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
  note=$(git notes --ref="$READ_REF" show "$oid" 2>/dev/null || true)
  if [[ -n "$note" ]]; then
    echo "$note"
    return
  fi

  # jj fallback: look up by change_id edge
  if [[ "$type" == "commit" ]] && { [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; }; then
    local _cid
    _cid=$(jj log -r "$oid" --no-graph -T 'change_id' 2>/dev/null || true)
    if [[ -n "$_cid" ]]; then
      local _found=""
      local notelist
      notelist=$(git notes --ref="$READ_REF" list 2>/dev/null || true)
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
  cat >&2 <<'EOF'
mycelium context moved out of the core CLI.
Use the workflow scripts from this repo's skill instead:
  scripts/context-workflow.sh <path> [ref]
  scripts/path-history.sh <path> [ref]      # optional historical file notes
EOF
  return 1


  local blob
  blob=$(git rev-parse "$at:$filepath" 2>/dev/null || true)
  if [[ -n "$blob" ]]; then
    while read -r sref; do
      local note
      note=$(git notes --ref="$sref" show "$blob" 2>/dev/null || true)
      [[ -z "$note" ]] && continue
      local kind title note_status slot_label
      kind=$(note_header "$note" "kind")
      title=$(note_header "$note" "title")
      note_status=$(note_header "$note" "status")
      [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
      slot_label="$(_slot_display "$sref")"
      echo "[exact] ${slot_label}${title:-$filepath} ($kind)"
      echo "$note"
      echo ""
    done < <(_each_ref aggregate "$slot")
  fi

  local path_target="path:$filepath"
  while read -r sref; do
    local notelist
    notelist=$(git notes --ref="$sref" list 2>/dev/null || true)
    while read -r noteblob obj; do
      [[ -z "$noteblob" ]] && continue
      [[ "$obj" == "${blob:-}" ]] && continue
      local content
      content=$(git cat-file -p "$noteblob")
      if echo "$content" | grep -q "targets-path $path_target"; then
        local kind title note_status slot_label slot_name read_hint
        kind=$(note_header "$content" "kind")
        title=$(note_header "$content" "title")
        note_status=$(note_header "$content" "status")
        [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
        slot_label="$(_slot_display "$sref")"
        slot_name=$(_slot_name_from_ref "$sref")
        read_hint="read ${obj:0:12}"
        [[ "$slot_name" != "default" ]] && read_hint+=" --slot $slot_name"
        if [[ "$show_all" == "true" ]]; then
          echo "[stale] ${slot_label}${title:-$filepath} ($kind) — blob changed since note was written"
          echo "$content"
          echo ""
        else
          echo "[stale] ${slot_label}${title:-$filepath} ($kind) — use '$read_hint' for full note"
        fi
      fi
    done <<< "$notelist"
  done < <(_each_ref aggregate "$slot")

  local dir="$filepath"
  while true; do
    dir=$(dirname "$dir")
    local tree dir_label
    if [[ "$dir" == "." ]]; then
      tree=$(git rev-parse "$at^{tree}" 2>/dev/null || true)
      dir_label="(root)"
    else
      tree=$(git rev-parse "$at:$dir" 2>/dev/null || true)
      dir_label="$dir"
    fi

    if [[ -n "$tree" ]]; then
      while read -r sref; do
        local note
        note=$(git notes --ref="$sref" show "$tree" 2>/dev/null || true)
        [[ -z "$note" ]] && continue
        local kind title note_status slot_label
        kind=$(note_header "$note" "kind")
        title=$(note_header "$note" "title")
        note_status=$(note_header "$note" "status")
        [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
        slot_label="$(_slot_display "$sref")"
        echo "[tree] ${slot_label}${title:-$dir_label} ($kind) — inherited"
        echo "$note"
        echo ""
      done < <(_each_ref aggregate "$slot")
    fi

    local treepath_target
    [[ "$dir" == "." ]] && treepath_target="treepath:." || treepath_target="treepath:$dir"
    while read -r sref; do
      local notelist
      notelist=$(git notes --ref="$sref" list 2>/dev/null || true)
      while read -r noteblob obj; do
        [[ -z "$noteblob" ]] && continue
        [[ "$obj" == "${tree:-}" ]] && continue
        local content
        content=$(git cat-file -p "$noteblob")
        if echo "$content" | grep -q "targets-treepath $treepath_target\$"; then
          local kind title note_status slot_label slot_name read_hint
          kind=$(note_header "$content" "kind")
          title=$(note_header "$content" "title")
          note_status=$(note_header "$content" "status")
          [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
          slot_label="$(_slot_display "$sref")"
          slot_name=$(_slot_name_from_ref "$sref")
          read_hint="read ${obj:0:12}"
          [[ "$slot_name" != "default" ]] && read_hint+=" --slot $slot_name"
          if [[ "$show_all" == "true" ]]; then
            echo "[stale-tree] ${slot_label}${title:-$dir_label} ($kind) — tree changed since note was written"
            echo "$content"
            echo ""
          else
            echo "[stale-tree] ${slot_label}${title:-$dir_label} ($kind) — use '$read_hint' for full note"
          fi
        fi
      done <<< "$notelist"
    done < <(_each_ref aggregate "$slot")

    [[ "$dir" == "." || "$dir" == "/" ]] && break
  done

  local commit
  commit=$(git rev-parse "$at" 2>/dev/null || true)
  if [[ -n "$commit" ]]; then
    while read -r sref; do
      local note
      note=$(git notes --ref="$sref" show "$commit" 2>/dev/null || true)
      [[ -z "$note" ]] && continue
      local kind title slot_label
      kind=$(note_header "$note" "kind")
      title=$(note_header "$note" "title")
      slot_label="$(_slot_display "$sref")"
      echo "[commit] ${slot_label}${title:-$at} ($kind)"
      echo "$note"
      echo ""
    done < <(_each_ref aggregate "$slot")
  fi

  # --- imported notes (read-only, foreign) ---
  while read -r iref; do
    [[ -z "$iref" ]] && continue
    local iname
    iname=$(_import_name_from_ref "$iref")

    # Check exact blob match
    if [[ -n "$blob" ]]; then
      local inote
      inote=$(git notes --ref="$iref" show "$blob" 2>/dev/null || true)
      if [[ -n "$inote" ]]; then
        local ikind ititle note_status
        ikind=$(note_header "$inote" "kind")
        ititle=$(note_header "$inote" "title")
        note_status=$(note_header "$inote" "status")
        [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
        echo "[import:$iname] ${ititle:-$filepath} ($ikind)"
        echo "$inote"
        echo ""
      fi
    fi

    # Check stale notes via path edge
    local inotelist
    inotelist=$(git notes --ref="$iref" list 2>/dev/null || true)
    while read -r inoteblob iobj; do
      [[ -z "$inoteblob" ]] && continue
      [[ "$iobj" == "${blob:-}" ]] && continue
      local icontent
      icontent=$(git cat-file -p "$inoteblob")
      if echo "$icontent" | grep -q "targets-path $path_target"; then
        local ikind ititle note_status
        ikind=$(note_header "$icontent" "kind")
        ititle=$(note_header "$icontent" "title")
        note_status=$(note_header "$icontent" "status")
        [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
        echo "[import:$iname] [stale] ${ititle:-$filepath} ($ikind)"
      fi
    done <<< "$inotelist"

    # Check for imported project-level (treepath:.) notes
    local iroot_note
    iroot_note=$(git notes --ref="$iref" show "$tree" 2>/dev/null || true) 2>/dev/null
    # Try root tree of current repo
    local local_root
    local_root=$(git rev-parse "$at^{tree}" 2>/dev/null || true)
    if [[ -n "$local_root" ]]; then
      # Scan import ref for treepath:. notes (project-level)
      while read -r inoteblob iobj; do
        [[ -z "$inoteblob" ]] && continue
        local icontent
        icontent=$(git cat-file -p "$inoteblob")
        if echo "$icontent" | grep -q "^edge targets-treepath treepath:\.\$"; then
          local ikind ititle note_status
          ikind=$(note_header "$icontent" "kind")
          ititle=$(note_header "$icontent" "title")
          note_status=$(note_header "$icontent" "status")
          [[ "$note_status" == "composted" && "$show_all" == "false" ]] && continue
          echo "[import:$iname] ${ititle:-(untitled)} ($ikind) — imported project-level"
          echo "$icontent"
          echo ""
        fi
      done <<< "$inotelist"
    fi
  done < <(_import_refs)
}

cmd_follow() {
  local target="" slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      target="$1"; shift ;;
    esac
  done
  target="${target:-HEAD}"
  _validate_slot "$slot" || exit 1

  local follow_ref
  follow_ref=$(_slot_ref "$slot")

  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  local note
  note=$(git notes --ref="$follow_ref" show "$oid" 2>/dev/null || true)
  if [[ -z "$note" ]]; then
    echo "(no mycelium note on $type:${oid:0:12})"
    return
  fi

  local kind title
  kind=$(note_header "$note" "kind")
  title=$(note_header "$note" "title")
  if [[ -n "$filepath" ]]; then
    echo "=== $type:${oid:0:12} ($filepath) [$kind] ${title:-} ==="
  else
    echo "=== $type:${oid:0:12} [$kind] ${title:-} ==="
  fi
  echo "$note"
  echo ""

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

    case "$target_type" in
      path|treepath)
        local resolved_oid
        resolved_oid=$(git rev-parse "HEAD:$target_ref" 2>/dev/null || true)
        if [[ -n "$resolved_oid" ]]; then
          local target_note
          target_note=$(git notes --ref="$follow_ref" show "$resolved_oid" 2>/dev/null || true)
          if [[ -n "$target_note" ]]; then
            local t_kind t_title
            t_kind=$(note_header "$target_note" "kind")
            t_title=$(note_header "$target_note" "title")
            echo "  $edge_type → $edge_target [$t_kind] ${t_title:-}"
          else
            echo "  $edge_type → $edge_target (no note)"
          fi
        else
          echo "  $edge_type → $edge_target (cannot resolve)"
        fi
        ;;
      note)
        local target_note
        target_note=$(git cat-file -p "$target_ref" 2>/dev/null || true)
        if [[ -n "$target_note" ]]; then
          local t_kind t_title
          t_kind=$(note_header "$target_note" "kind")
          t_title=$(note_header "$target_note" "title")
          echo "  $edge_type → note:${target_ref:0:12} [$t_kind] ${t_title:-}"
        else
          echo "  $edge_type → note:${target_ref:0:12} (cannot resolve)"
        fi
        ;;
      blob|tree|commit|tag)
        local target_note
        target_note=$(git notes --ref="$follow_ref" show "$target_ref" 2>/dev/null || true)
        if [[ -n "$target_note" ]]; then
          local t_kind t_title
          t_kind=$(note_header "$target_note" "kind")
          t_title=$(note_header "$target_note" "title")
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
  local target="" slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      target="$1"; shift ;;
    esac
  done
  target="${target:-HEAD}"
  _validate_slot "$slot" || exit 1

  local refs_ref
  refs_ref=$(_slot_ref "$slot")

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

  local notelist
  notelist=$(git notes --ref="$refs_ref" list 2>/dev/null || true)
  while read -r noteblob obj; do
    [[ -z "$noteblob" ]] && continue
    local content match label kind title edges
    content=$(git cat-file -p "$noteblob")
    match=false

    if echo "$content" | grep -q "^edge .* .*:$oid"; then
      match=true
    fi
    if [[ -n "$filepath" ]] && echo "$content" | grep -q "^edge .* path:$filepath\$"; then
      match=true
    fi
    if [[ -n "$filepath" ]] && echo "$content" | grep -q "^edge .* treepath:$filepath\$"; then
      match=true
    fi

    if [[ "$match" == "true" ]]; then
      label=$(obj_label "$obj")
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      edges=$(echo "$content" | grep "^edge .* .*:$oid\|^edge .* path:${filepath:-__NOMATCH__}\|^edge .* treepath:${filepath:-__NOMATCH__}" || true)
      echo "$label [$kind] ${title:-}"
      echo "$edges" | sed 's/^/  /'
      echo ""
    fi
  done <<< "$notelist"
}

cmd_kinds() {
  local slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done
  _validate_slot "$slot" || exit 1

  echo "Kinds in use:"
  {
    while read -r sref; do
      git notes --ref="$sref" list 2>/dev/null | while read -r blob obj; do
        [[ -z "$blob" ]] && continue
        git cat-file -p "$blob" | grep "^kind " | cut -d' ' -f2
      done
    done < <(_each_ref aggregate "$slot")
    # Include imported note kinds
    while read -r iref; do
      [[ -z "$iref" ]] && continue
      git notes --ref="$iref" list 2>/dev/null | while read -r blob obj; do
        [[ -z "$blob" ]] && continue
        git cat-file -p "$blob" | grep "^kind " | cut -d' ' -f2
      done
    done < <(_import_refs)
  } | sort | uniq -c | sort -rn | while read -r count kind; do
    printf "  %-20s %s note(s)\n" "$kind" "$count"
  done
}

cmd_edges() {
  local filter="" slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      [[ -z "$filter" ]] && filter="$1" || { echo "Unknown argument: $1" >&2; exit 1; }; shift ;;
    esac
  done
  _validate_slot "$slot" || exit 1

  while read -r sref; do
    git notes --ref="$sref" list 2>/dev/null | while read -r blob obj; do
      [[ -z "$blob" ]] && continue
      local label edges
      label=$(obj_label "$obj")
      edges=$(git cat-file -p "$blob" | grep '^edge ' || true)
      if [[ -n "$edges" ]]; then
        if [[ -z "$filter" ]]; then
          echo "$edges" | sed "s/^/[$label] /"
        else
          echo "$edges" | grep "^edge $filter " | sed "s/^/[$label] /" || true
        fi
      fi
    done
  done < <(_each_ref exact "$slot")
}

cmd_find() {
  local kind="" slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      [[ -z "$kind" ]] && kind="$1" || { echo "Unknown argument: $1" >&2; exit 1; }; shift ;;
    esac
  done
  [[ -z "$kind" ]] && { echo "Usage: mycelium find <kind> [--slot <name>]" >&2; exit 1; }
  _validate_slot "$slot" || exit 1

  while read -r sref; do
    local slot_label
    slot_label="$(_slot_display "$sref")"
    git notes --ref="$sref" list 2>/dev/null | while read -r blob obj; do
      [[ -z "$blob" ]] && continue
      local content
      content=$(git cat-file -p "$blob")
      if echo "$content" | grep -q "^kind $kind\$"; then
        local label title
        label=$(obj_label "$obj")
        title=$(note_header "$content" "title")
        if [[ -n "$title" ]]; then
          echo "$label  ${slot_label}$title"
        else
          local body
          body=$(echo "$content" | sed -n '/^$/,$ p' | sed '/^$/d' | head -1)
          echo "$label  ${slot_label}${body:-(no title)}"
        fi
      fi
    done
  done < <(_each_ref aggregate "$slot")

  # --- imported notes ---
  while read -r iref; do
    [[ -z "$iref" ]] && continue
    local iname
    iname=$(_import_name_from_ref "$iref")
    git notes --ref="$iref" list 2>/dev/null | while read -r blob obj; do
      [[ -z "$blob" ]] && continue
      local content
      content=$(git cat-file -p "$blob")
      if echo "$content" | grep -q "^kind $kind\$"; then
        local label title
        label=$(obj_label "$obj")
        title=$(note_header "$content" "title")
        if [[ -n "$title" ]]; then
          echo "$label  [import:$iname] $title"
        else
          local body
          body=$(echo "$content" | sed -n '/^$/,$ p' | sed '/^$/d' | head -1)
          echo "$label  [import:$iname] ${body:-(no title)}"
        fi
      fi
    done
  done < <(_import_refs)
}

cmd_log() {
  local n="${1:-20}"
  git log --notes="$REF" --oneline -"$n"
}

cmd_list() {
  local slot=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slot) slot="$2"; shift 2 ;;
      -*)     echo "Unknown option: $1" >&2; exit 1 ;;
      *)      echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
  done
  _validate_slot "$slot" || exit 1

  while read -r sref; do
    git notes --ref="$sref" list 2>/dev/null | while read -r blob obj; do
      [[ -z "$blob" ]] && continue
      local label content kind title
      label=$(obj_label "$obj")
      content=$(git cat-file -p "$blob")
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      echo "$label  [$kind] ${title:-}"
    done
  done < <(_each_ref exact "$slot")
}

cmd_activate() {
  git config --add notes.displayRef "$NOTES_REF"
  git config --add notes.displayRef "refs/notes/${REF}--slot--*"
  echo "Mycelium notes now visible in git log."
}

cmd_sync_init() {
  local remote="" export_only=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --export-only) export_only=true; shift ;;
      -*)            echo "Unknown option: $1" >&2; exit 1 ;;
      *)             remote="$1"; shift ;;
    esac
  done
  remote="${remote:-origin}"

  if [[ "$export_only" == "true" ]]; then
    # Only configure export refs — working ref, slots, and imports stay local
    git config --add "remote.$remote.fetch" "+refs/notes/${REF}--export--internal:refs/notes/${REF}--export--internal"
    git config --add "remote.$remote.push" "refs/notes/${REF}--export--internal:refs/notes/${REF}--export--internal"
    git config --add "remote.$remote.fetch" "+refs/notes/${REF}--export--public:refs/notes/${REF}--export--public"
    git config --add "remote.$remote.push" "refs/notes/${REF}--export--public:refs/notes/${REF}--export--public"
    echo "Export-only refspecs added for $remote. Run: git fetch $remote && git push $remote"
  else
    # Backward compatible: push working ref + slots (existing behavior)
    git config --add "remote.$remote.fetch" "+$NOTES_REF:$NOTES_REF"
    git config --add "remote.$remote.push" "$NOTES_REF:$NOTES_REF"
    git config --add "remote.$remote.fetch" "+refs/notes/${REF}--slot--*:refs/notes/${REF}--slot--*"
    git config --add "remote.$remote.push" "refs/notes/${REF}--slot--*:refs/notes/${REF}--slot--*"
    echo "Refspecs added for $remote. Run: git fetch $remote && git push $remote"
  fi
}

# --- multi-repo: identity, zone, export ---

cmd_repo_id() {
  local subcmd="${1:-}"
  case "$subcmd" in
    init)
      if [[ -f .mycelium/repo-id ]]; then
        cat .mycelium/repo-id
        return
      fi
      mkdir -p .mycelium
      # Generate a random hex id (16 bytes = 32 hex chars)
      local id
      id=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
      echo "$id" > .mycelium/repo-id
      echo "$id"
      ;;
    "")
      if [[ -f .mycelium/repo-id ]]; then
        cat .mycelium/repo-id
      else
        echo "Error: no repo-id. Run: mycelium.sh repo-id init && git add .mycelium/repo-id && git commit -m 'add repo identity'" >&2
        return 1
      fi
      ;;
    *)
      echo "Usage: mycelium.sh repo-id [init]" >&2
      return 1
      ;;
  esac
}

cmd_zone() {
  local subcmd="${1:-}"
  case "$subcmd" in
    init)
      local level="${2:-80}"
      if ! [[ "$level" =~ ^[0-9]+$ ]]; then
        echo "Error: zone level must be a non-negative integer (got: $level)" >&2
        return 1
      fi
      mkdir -p .mycelium
      echo "$level" > .mycelium/zone
      echo "$level"
      ;;
    "")
      if [[ -f .mycelium/zone ]]; then
        cat .mycelium/zone
      else
        echo "Error: no zone. Run: mycelium.sh zone init [level]" >&2
        return 1
      fi
      ;;
    *)
      # Bare number = show, anything else = error
      echo "Usage: mycelium.sh zone [init [level]]" >&2
      return 1
      ;;
  esac
}

_validate_audience() {
  local audience="$1"
  if [[ -z "$audience" ]]; then
    echo "Error: --audience is required (internal or public)" >&2
    return 1
  fi
  if echo "$audience" | grep -q -- '--slot--\|--export--'; then
    echo "Error: audience name cannot contain '--slot--' or '--export--'" >&2
    return 1
  fi
  case "$audience" in
    internal|public) return 0 ;;
    *) echo "Error: audience must be 'internal' or 'public'" >&2; return 1 ;;
  esac
}

_check_export_policy() {
  # Validate note content against export-policy for public exports.
  # Reads policy from committed state (HEAD), not working tree.
  # Returns 0 if allowed, 1 if denied (with message on stderr).
  local content="$1"

  local policy
  policy=$(git show HEAD:.mycelium/export-policy 2>/dev/null || echo "")
  [[ -z "$policy" ]] && return 0  # no policy = permissive

  # Parse allowed_kinds
  local allowed_kinds
  allowed_kinds=$(echo "$policy" | grep '^allowed_kinds' | sed 's/^allowed_kinds *= *//' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
  if [[ -n "$allowed_kinds" ]]; then
    local note_kind
    note_kind=$(echo "$content" | awk '/^kind /{print $2; exit}')
    if ! echo "$allowed_kinds" | grep -qxF "$note_kind"; then
      echo "Error: kind '$note_kind' not in allowed_kinds for public export" >&2
      return 1
    fi
  fi

  # Parse deny_patterns
  local deny_patterns
  deny_patterns=$(echo "$policy" | grep '^deny_patterns' | sed 's/^deny_patterns *= *//' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
  if [[ -n "$deny_patterns" ]]; then
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      # Convert glob-style pattern to grep pattern (only * wildcard)
      local grep_pattern
      grep_pattern=$(echo "$pattern" | sed 's/[.[\\^$()+?{|]/\\&/g; s/\*/.*/g')
      if echo "$content" | grep -q "$grep_pattern"; then
        echo "Error: note body matches deny_pattern '$pattern'" >&2
        return 1
      fi
    done <<< "$deny_patterns"
  fi

  # Check forbid_imported_taint
  local forbid_taint
  forbid_taint=$(echo "$policy" | grep '^forbid_imported_taint' | sed 's/^forbid_imported_taint *= *//')
  if [[ "$forbid_taint" == "true" ]]; then
    if echo "$content" | grep -q '^taint '; then
      echo "Error: note has taint header; public export forbidden by policy (forbid_imported_taint=true)" >&2
      return 1
    fi
  fi

  return 0
}

cmd_export() {
  local target="" audience="" slot=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --audience)  audience="$2"; shift 2 ;;
      --slot)      slot="$2"; shift 2 ;;
      -*)          echo "Unknown option: $1" >&2; exit 1 ;;
      *)           target="$1"; shift ;;
    esac
  done

  # --audience is required
  _validate_audience "${audience:-}" || exit 1

  [[ -z "$target" ]] && { echo "Usage: mycelium.sh export <target> --audience <internal|public> [--slot <name>]" >&2; exit 1; }

  # repo-id must exist
  if [[ ! -f .mycelium/repo-id ]]; then
    echo "Error: .mycelium/repo-id not found" >&2
    echo "  Run: mycelium.sh repo-id init && git add .mycelium/repo-id && git commit -m 'add repo identity'" >&2
    exit 1
  fi
  local repo_id
  repo_id=$(cat .mycelium/repo-id)

  # Resolve target
  local resolved
  resolved=$(resolve_target "$target") || exit 1
  local oid type filepath
  oid=$(echo "$resolved" | cut -d' ' -f1)
  type=$(echo "$resolved" | cut -d' ' -f2)
  filepath=$(echo "$resolved" | cut -d' ' -f3-)

  # Determine source ref (default or slot)
  _validate_slot "$slot" || exit 1
  local SOURCE_REF
  SOURCE_REF=$(_slot_ref "$slot")

  # Read the note from source ref
  local content
  content=$(git notes --ref="$SOURCE_REF" show "$oid" 2>/dev/null || true)
  if [[ -z "$content" ]]; then
    echo "Error: no note on ${type}:${oid:0:12} in $SOURCE_REF" >&2
    exit 1
  fi

  # Policy check for public audience
  if [[ "$audience" == "public" ]]; then
    _check_export_policy "$content" || exit 1
  fi

  # Build export ref name
  local EXPORT_REF="${REF}--export--${audience}"

  # Add exported-from edge if not already present
  local export_content="$content"
  if ! echo "$content" | grep -q "^edge exported-from "; then
    # Insert the edge after the last existing edge line, or after headers
    export_content=$(echo "$content" | awk -v edge="edge exported-from repo:$repo_id" '
      /^edge / { last_edge=NR }
      { lines[NR]=$0 }
      END {
        if (last_edge) {
          for (i=1; i<=NR; i++) {
            print lines[i]
            if (i==last_edge) print edge
          }
        } else {
          # No existing edges — insert before blank line (body separator)
          done=0
          for (i=1; i<=NR; i++) {
            if (!done && lines[i]=="") { print edge; done=1 }
            print lines[i]
          }
          if (!done) print edge
        }
      }
    ')
  fi

  # Write to export ref
  git notes --ref="$EXPORT_REF" add -f -m "$export_content" "$oid" 2>/dev/null

  echo "$oid"
  if [[ -n "$filepath" ]]; then
    echo "  exported to $audience (path:$filepath)" >&2
  else
    echo "  exported to $audience (${type}:${oid:0:12})" >&2
  fi
}

cmd_import() {
  local remote="" alias="" audience="internal" refresh=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --as)        alias="$2"; shift 2 ;;
      --audience)  audience="$2"; shift 2 ;;
      --refresh)   refresh=true; shift ;;
      -*)          echo "Unknown option: $1" >&2; exit 1 ;;
      *)           remote="$1"; shift ;;
    esac
  done

  [[ -z "$remote" ]] && { echo "Usage: mycelium.sh import <remote> [--as <name>] [--audience internal|public] [--refresh]" >&2; exit 1; }

  local remote_ref="refs/notes/${REF}--export--${audience}"
  local temp_ref="${REF}--import--_discovering-$$"

  # If --refresh with known alias, skip discovery — fetch directly
  if [[ "$refresh" == "true" && -n "$alias" ]]; then
    local target_ref="${REF}--import--${alias}"
    if ! git rev-parse --verify "refs/notes/$target_ref" &>/dev/null; then
      echo "Error: no existing import '$alias' to refresh" >&2
      exit 1
    fi
    git fetch "$remote" "+${remote_ref}:refs/notes/$target_ref" 2>/dev/null || {
      echo "Error: could not fetch $remote_ref from $remote" >&2
      exit 1
    }
    # Wrapper commit for freshness tracking
    _import_wrapper_commit "$target_ref" "$remote"
    local count
    count=$(git notes --ref="$target_ref" list 2>/dev/null | wc -l)
    echo "Refreshed import '$alias' from $remote ($count notes)" >&2
    echo "$alias"
    return
  fi

  # If --refresh without alias, try to auto-discover existing import
  if [[ "$refresh" == "true" && -z "$alias" ]]; then
    # Find existing import ref for this remote by checking all imports
    # For simplicity, require --as on refresh without alias
    echo "Error: --refresh requires --as <name> to identify which import to refresh" >&2
    exit 1
  fi

  # Determine identifier: alias or auto-discover from exported-from edge
  local identifier=""
  if [[ -n "$alias" ]]; then
    identifier="$alias"
    local target_ref="${REF}--import--${identifier}"
    # Direct fetch into target ref
    git fetch "$remote" "+${remote_ref}:refs/notes/$target_ref" 2>/dev/null || {
      echo "Error: could not fetch $remote_ref from $remote (does the remote have exported notes?)" >&2
      exit 1
    }
  else
    # Fetch into temp ref, discover repo-id from exported-from edge
    git fetch "$remote" "+${remote_ref}:refs/notes/$temp_ref" 2>/dev/null || {
      echo "Error: could not fetch $remote_ref from $remote (does the remote have exported notes?)" >&2
      exit 1
    }

    # Read repo-id from first note's exported-from edge
    local first_blob
    first_blob=$(git notes --ref="$temp_ref" list 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -z "$first_blob" ]]; then
      git update-ref -d "refs/notes/$temp_ref" 2>/dev/null || true
      echo "Error: export ref from $remote is empty" >&2
      exit 1
    fi

    local repo_id
    repo_id=$(git cat-file -p "$first_blob" 2>/dev/null | grep '^edge exported-from repo:' | head -1 | sed 's/^edge exported-from repo://')
    if [[ -z "$repo_id" ]]; then
      git update-ref -d "refs/notes/$temp_ref" 2>/dev/null || true
      echo "Error: could not discover repo-id from exported notes. Use --as <name> to specify manually." >&2
      exit 1
    fi

    identifier="$repo_id"
    local target_ref="${REF}--import--${identifier}"

    # Rename temp ref to permanent
    local tip
    tip=$(git rev-parse "refs/notes/$temp_ref")
    git update-ref "refs/notes/$target_ref" "$tip"
    git update-ref -d "refs/notes/$temp_ref" 2>/dev/null || true
  fi

  # Wrapper commit for freshness tracking
  local target_ref="${REF}--import--${identifier}"
  _import_wrapper_commit "$target_ref" "$remote"

  local count
  count=$(git notes --ref="$target_ref" list 2>/dev/null | wc -l)
  echo "Imported $count notes from $remote as '$identifier'" >&2
  echo "$identifier"
}

_import_wrapper_commit() {
  # Add a wrapper commit on the import ref for freshness tracking.
  # The commit message records when and from where the import happened.
  local ref="$1" remote="$2"
  local tree parent new_commit
  tree=$(git rev-parse "refs/notes/$ref^{tree}" 2>/dev/null) || return 0
  parent=$(git rev-parse "refs/notes/$ref" 2>/dev/null) || return 0
  # Use git's own timestamp (GIT_COMMITTER_DATE is set automatically by git commit-tree)
  new_commit=$(git commit-tree "$tree" -p "$parent" -m "mycelium import from $remote" 2>/dev/null) || return 0
  git update-ref "refs/notes/$ref" "$new_commit"
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
        _validate_branch_name "$name" || return 1
        echo "mycelium--$name" > "$_git_dir/mycelium-branch"
        echo "Switched to branch ref: refs/notes/mycelium--$name"
      fi
      ;;
    merge)
      local name="${2:?usage: mycelium branch merge <name>}"
      _validate_branch_name "$name" || return 1

      merge_one_ref() {
        local src_ref="$1" dst_ref="$2"
        local notelist
        notelist=$(git notes --ref="$src_ref" list 2>/dev/null || true)
        [[ -z "$notelist" ]] && return 0
        while read -r noteblob obj; do
          [[ -z "$noteblob" ]] && continue
          local existing
          existing=$(git notes --ref="$dst_ref" list "$obj" 2>/dev/null | awk '{print $1}' || true)
          git notes --ref="$dst_ref" add -f -C "$noteblob" "$obj"
          count=$((count + 1))
        done <<< "$notelist"
      }

      local source_base="mycelium--$name"
      local source_refs=("$source_base")
      while IFS= read -r r; do
        [[ -n "$r" ]] && source_refs+=("${r#notes/}")
      done < <(git for-each-ref --format='%(refname:short)' "refs/notes/${source_base}--slot--*" 2>/dev/null)

      local count=0
      local saw_any=false
      local src_ref dst_ref
      for src_ref in "${source_refs[@]}"; do
        dst_ref="$REF${src_ref#"$source_base"}"
        if [[ -n "$(git notes --ref="$src_ref" list 2>/dev/null || true)" ]]; then
          saw_any=true
        fi
        merge_one_ref "$src_ref" "$dst_ref"
      done

      [[ "$saw_any" == "false" ]] && { echo "No notes in refs/notes/$source_base"; return 1; }
      echo "Merged $count note(s) from $source_base into $REF."
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

  # Classify each note across all slots
  local notelist
  notelist=$(_all_notes)
  if [[ -z "$notelist" ]]; then
    echo "notes  0"
  else

  while read sref noteblob obj; do
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

  # Slots: count active slot refs
  local slot_count=0
  while read -r sref; do
    local scount
    scount=$(git notes --ref="$sref" list 2>/dev/null | wc -l || true)
    [[ "$scount" -gt 0 ]] && slot_count=$((slot_count + 1))
  done < <(_all_slot_refs)
  if [[ $slot_count -gt 1 ]]; then
    echo "slots  $slot_count"
  fi

  fi  # end of [[ -z "$notelist" ]] else block

  # jj: report colocated status
  if [[ -d "$_git_dir/../.jj" ]] || [[ -d ".jj" ]]; then
    local jj_ver
    jj_ver=$(jj version 2>/dev/null | head -1 || echo "unknown")
    echo "jj     colocated ($jj_ver)"
  fi

  # Imports: report each imported ref with note count and freshness
  local has_imports=false
  while read -r iref; do
    [[ -z "$iref" ]] && continue
    has_imports=true
    local iname icount ifresh
    iname=$(_import_name_from_ref "$iref")
    icount=$(git notes --ref="$iref" list 2>/dev/null | wc -l || echo "0")
    ifresh=$(git log -1 --format='%ci' "refs/notes/$iref" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
    echo "import $iname  $icount note(s)  fetched:$ifresh"
  done < <(_import_refs)

  rm -f "$tmp"
}

# --- compost helpers (shared by direct + interactive paths) ---

# Mark a note as composted by OID, in a specific ref
_compost_note() {
  local obj="$1"
  local cref="${2:-$REF}"
  local content
  content=$(git notes --ref="$cref" show "$obj" 2>/dev/null || true)
  [[ -z "$content" ]] && { echo "Error: no note on $obj in $cref" >&2; return 1; }

  local new_content
  if echo "$content" | grep -q '^status '; then
    new_content=$(echo "$content" | sed 's/^status .*/status composted/')
  else
    new_content=$(echo "$content" | awk '/^kind /{print; print "status composted"; next} {print}')
  fi
  git notes --ref="$cref" add -f -m "$new_content" "$obj" 2>/dev/null
}

# Re-attach a note to the current blob/tree at its path, in a specific ref
_renew_note() {
  local obj="$1"
  local rref="${2:-$REF}"
  local content
  content=$(git notes --ref="$rref" show "$obj" 2>/dev/null || true)
  [[ -z "$content" ]] && { echo "Error: no note on $obj in $rref" >&2; return 1; }

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

  # Check if new object already has a note IN THIS SAME REF
  local existing_on_new
  existing_on_new=$(git notes --ref="$rref" list "$current_oid" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -n "$existing_on_new" ]]; then
    echo "Error: current version already has a note in $rref" >&2
    return 1
  fi

  # Update applies-to edge and write on new object
  local new_content
  new_content=$(echo "$content" | sed "s|^edge applies-to [a-z]*:.*|edge applies-to $current_type:$current_oid|")
  git notes --ref="$rref" add -f -m "$new_content" "$current_oid" 2>/dev/null

  # Compost the old one
  _compost_note "$obj" "$rref"
  echo "$current_oid"
}

# Find which refs have a note on a given OID
_find_refs_for_oid() {
  local oid="$1"
  while read -r sref; do
    if git notes --ref="$sref" list "$oid" &>/dev/null; then
      echo "$sref"
    fi
  done < <(_all_slot_refs)
}

# Collect stale notes across all slots, optionally filtered by path and slot
_collect_stale() {
  local target="${1:-.}"
  local filter_slot="${2:-}"
  local notelist
  notelist=$(_all_notes)
  [[ -z "$notelist" ]] && return

  while read sref noteblob obj; do
    # Filter by slot if specified
    if [[ -n "$filter_slot" ]]; then
      local expected_ref
      expected_ref=$(_slot_ref "$filter_slot")
      [[ "$sref" != "$expected_ref" ]] && continue
    fi

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
      # Output: ref\tobj\tpath\tkind\ttitle
      printf '%s\t%s\t%s\t%s\t%s\n' "$sref" "$obj" "$note_target" "$kind" "${title:-(untitled)}"
    fi
  done <<< "$notelist"
}

cmd_compost() {
  local target="" action="" dry_run=false slot=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)   dry_run=true; shift ;;
      --report)    action="report"; shift ;;
      --compost)   action="compost"; shift ;;
      --renew)     action="renew"; shift ;;
      --slot)      slot="$2"; shift 2 ;;
      -*)          echo "Unknown option: $1" >&2; exit 1 ;;
      *)           target="$1"; shift ;;
    esac
  done
  target="${target:-.}"

  # Guard against writes to import/export refs
  _assert_writable_ref "$REF" || exit 1

  # --- Resolve OID for direct actions ---
  # Helper: find full OID and its ref(s) from a short OID prefix
  _resolve_oid_for_compost() {
    local short="$1" slot="$2"
    local matches=()
    while read -r sref; do
      local full
      full=$(git notes --ref="$sref" list 2>/dev/null | awk -v t="$short" '$2 ~ "^"t {print $2; exit}')
      if [[ -n "$full" ]]; then
        matches+=("$sref:$full")
      fi
    done < <(_all_slot_refs)

    if [[ ${#matches[@]} -eq 0 ]]; then
      echo "Error: no note on object matching $short" >&2
      return 1
    fi

    # If slot specified, filter to that slot
    if [[ -n "$slot" ]]; then
      local slot_ref
      slot_ref=$(_slot_ref "$slot")
      for m in "${matches[@]}"; do
        local mref="${m%%:*}"
        local moid="${m#*:}"
        if [[ "$mref" == "$slot_ref" ]]; then
          echo "$mref $moid"
          return 0
        fi
      done
      echo "Error: no note on $short in slot '$slot'" >&2
      return 1
    fi

    # No slot: if multiple refs match, error (ambiguous)
    if [[ ${#matches[@]} -gt 1 ]]; then
      echo "Error: ambiguous — $short has notes in multiple slots:" >&2
      for m in "${matches[@]}"; do
        local mref="${m%%:*}"
        local slot_name
        slot_name=$(_slot_name_from_ref "$mref")
        echo "  ${slot_name:-default}" >&2
      done
      echo "Use --slot to specify which one" >&2
      return 1
    fi

    local mref="${matches[0]%%:*}"
    local moid="${matches[0]#*:}"
    echo "$mref $moid"
  }

  # Direct action (agent-native)
  if [[ "$action" == "compost" && "$target" != "." ]]; then
    # Is target an OID?
    if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
      local resolved_oid
      resolved_oid=$(_resolve_oid_for_compost "$target" "$slot") || exit 1
      local cref="${resolved_oid%% *}" full_oid="${resolved_oid#* }"
      _compost_note "$full_oid" "$cref"
      local content title kind
      content=$(git notes --ref="$cref" show "$full_oid" 2>/dev/null || true)
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      echo "✓ composted [$kind] ${title:-(untitled)}"
      return
    fi
    # Path: batch compost all stale notes on this path (across slots, or filtered)
    local found=false
    while IFS=$'\t' read -r sref obj note_path kind title; do
      _compost_note "$obj" "$sref"
      local slot_label=$(_slot_display "$sref")
      echo "✓ composted ${slot_label}[$kind] $title — $note_path"
      found=true
    done < <(_collect_stale "$target" "$slot")
    if [[ "$found" == "false" ]]; then
      echo "No stale notes under $target"
    fi
    return
  fi

  if [[ "$action" == "renew" && "$target" != "." ]]; then
    # Is target an OID?
    if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
      local resolved_oid
      resolved_oid=$(_resolve_oid_for_compost "$target" "$slot") || exit 1
      local rref="${resolved_oid%% *}" full_oid="${resolved_oid#* }"
      local new_oid
      new_oid=$(_renew_note "$full_oid" "$rref") || exit 1
      local content title kind
      content=$(git notes --ref="$rref" show "$new_oid" 2>/dev/null || true)
      kind=$(note_header "$content" "kind")
      title=$(note_header "$content" "title")
      echo "✓ renewed [$kind] ${title:-(untitled)} → ${new_oid:0:12}"
      return
    fi
    # Path: batch renew
    local found=false
    while IFS=$'\t' read -r sref obj note_path kind title; do
      local new_oid
      new_oid=$(_renew_note "$obj" "$sref") && {
        local slot_label=$(_slot_display "$sref")
        echo "✓ renewed ${slot_label}[$kind] $title — $note_path → ${new_oid:0:12}"
        found=true
      }
    done < <(_collect_stale "$target" "$slot")
    if [[ "$found" == "false" ]]; then
      echo "No stale notes under $target"
    fi
    return
  fi

  # Report mode — scan all slots
  if [[ "$action" == "report" ]]; then
    local stale_count=0 composted_count=0
    local notelist
    notelist=$(_all_notes)
    [[ -z "$notelist" ]] && { echo "mycelium: 0 stale, 0 composted"; return; }
    while read sref noteblob obj; do
      local content
      content=$(git cat-file -p "$noteblob")
      local ns
      ns=$(note_header "$content" "status")
      if [[ "$ns" == "composted" ]]; then
        composted_count=$((composted_count + 1))
      else
        local tp tt
        tp=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
        tt=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')
        if [[ -n "$tp" ]]; then
          local cb
          cb=$(git rev-parse "HEAD:$tp" 2>/dev/null || true)
          if [[ -n "$cb" && "$cb" != "$obj" ]] || [[ -z "$cb" ]]; then
            stale_count=$((stale_count + 1))
          fi
        elif [[ -n "$tt" && "$tt" != "." ]]; then
          local ct
          ct=$(git rev-parse "HEAD:$tt" 2>/dev/null || true)
          if [[ -n "$ct" && "$ct" != "$obj" ]] || [[ -z "$ct" ]]; then
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
  stale_lines=$(_collect_stale "$target" "$slot")
  local stale_count
  if [[ -z "$stale_lines" ]]; then
    echo "No stale notes${target:+ under $target}."
    return
  fi
  stale_count=$(echo "$stale_lines" | wc -l)

  echo "$stale_count stale note(s)${target:+ under $target}:"
  echo ""

  while IFS=$'\t' read -r sref obj note_path kind title; do
    local slot_label=$(_slot_display "$sref")
    echo "  ${slot_label}[$kind] ${title} — $note_path (${obj:0:12})"

    [[ "$dry_run" == "true" ]] && continue

    # Interactive: show note and ask
    local content
    content=$(git notes --ref="$sref" show "$obj" 2>/dev/null)
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
          _compost_note "$obj" "$sref"
          echo "  ✓ composted"
          echo ""
          break ;;
        r|renew)
          local new_oid
          new_oid=$(_renew_note "$obj" "$sref") && echo "  ✓ renewed → ${new_oid:0:12}" || true
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

cmd_migrate() {
  local dry_run=false map_file="" ref="$NOTES_REF"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) dry_run=true; shift ;;
      --map)     map_file="$2"; shift 2 ;;
      --ref)     ref="$2"; shift 2 ;;
      *)         echo "Usage: mycelium migrate [--dry-run] [--map <file>] [--ref <ref>]" >&2; exit 1 ;;
    esac
  done

  # Build mapping: old_oid -> new_oid
  # Source 1: explicit map file (old_oid new_oid change_id)
  # Source 2: jj predecessor info (auto-detect)
  declare -A oid_map  # old_oid -> new_oid

  if [[ -n "$map_file" ]]; then
    while read -r old_oid new_oid cid rest; do
      [[ -z "$old_oid" || "$old_oid" == "#"* ]] && continue
      oid_map["$old_oid"]="$new_oid"
    done < "$map_file"
  elif [[ -d ".jj" ]] || [[ -d "$_git_dir/../.jj" ]]; then
    # Auto-resolve via jj: find notes with targets-change edges, resolve current OID
    echo "jj colocated repo detected — auto-resolving via change_id edges" >&2
    if ! command -v jj &>/dev/null; then
      echo "jj not found — provide --map file or install jj" >&2
      exit 1
    fi
    # Scan all notes for targets-change edges on commit objects
    git notes --ref="$ref" list 2>/dev/null | while read -r noteblob obj; do
      [[ -z "$noteblob" ]] && continue
      local otype
      otype=$(git cat-file -t "$obj" 2>/dev/null || echo "unknown")
      [[ "$otype" != "commit" ]] && continue
      local content
      content=$(git cat-file -p "$noteblob")
      local cid
      cid=$(echo "$content" | grep '^edge targets-change change:' | head -1 | sed 's/^edge targets-change change://')
      [[ -z "$cid" ]] && continue
      # Resolve change_id to current commit
      local current_oid
      current_oid=$(jj log -r "$cid" --no-graph -T 'commit_id' 2>/dev/null || true)
      [[ -z "$current_oid" ]] && continue
      [[ "$current_oid" == "$obj" ]] && continue  # no rewrite
      oid_map["$obj"]="$current_oid"
    done
  else
    echo "No --map file and no jj repo detected. Nothing to migrate." >&2
    echo "Usage: mycelium migrate [--dry-run] [--map <file>]" >&2
    exit 1
  fi

  local reattached=0 skipped=0 total=0

  # Walk all notes on the ref looking for ones attached to old OIDs in the map
  local notelist
  notelist=$(git notes --ref="$ref" list 2>/dev/null || true)
  while read -r noteblob obj; do
    [[ -z "$noteblob" ]] && continue
    local new_oid="${oid_map[$obj]:-}"
    [[ -z "$new_oid" ]] && continue
    total=$((total + 1))

    local content
    content=$(git cat-file -p "$noteblob")
    local title
    title=$(note_header "$content" "title")

    # Check for conflict: new OID already has a note
    if git notes --ref="$ref" show "$new_oid" &>/dev/null; then
      echo "  skip: ${title:-(untitled)} — target ${new_oid:0:12} already has a note" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if $dry_run; then
      echo "  dry-run: would reattach \"${title:-(untitled)}\" ${obj:0:12} → ${new_oid:0:12}" >&2
    else
      # Update the explains commit: edge in the note body
      local new_content
      new_content=$(echo "$content" | sed "s|^edge explains commit:${obj}|edge explains commit:${new_oid}|")
      # Attach to new OID
      echo "$new_content" | git notes --ref="$ref" add -f -F - "$new_oid" 2>/dev/null
      # Remove from old OID
      git notes --ref="$ref" remove "$obj" 2>/dev/null || true
      echo "  reattached: \"${title:-(untitled)}\" ${obj:0:12} → ${new_oid:0:12}" >&2
    fi
    reattached=$((reattached + 1))
  done <<< "$notelist"

  if $dry_run; then
    echo "dry-run: $reattached to reattach, $skipped to skip" >&2
  else
    echo "migrate: $reattached reattached, $skipped skipped" >&2
  fi
}

cmd_dump() {
  _all_notes | while read sref blob obj; do
    local label=$(obj_label "$obj")
    local slot_label=$(_slot_display "$sref")
    echo "=== ${slot_label}$label ==="
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
scripts/context-workflow.sh <path>   # recommended arrival workflow
mycelium.sh read [target]            # read a single note
mycelium.sh note <target> -k <kind> -m <body>  # write a note
mycelium.sh find <kind>              # find all notes of a kind
scripts/note-history.sh <target>     # note overwrite history via git
mycelium.sh doctor                   # graph state
```
SKILL
  fi

  # 2. Live repo state — check all slots
  local notelist
  notelist=$(_all_notes)
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
  echo '```'

  # 3. Root tree notes — scan all slots
  local root_tree
  root_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)
  if [[ -n "$root_tree" ]]; then
    while read -r sref; do
      local root_note
      root_note=$(git notes --ref="$sref" show "$root_tree" 2>/dev/null || true)
      if [[ -n "$root_note" ]]; then
        local slot_label=$(_slot_display "$sref")
        echo ""
        echo "### ${slot_label}Project notes"
        echo ""
        echo "$root_note"
      fi
    done < <(_all_slot_refs)
  fi

  # Stale root tree notes — scan all slots
  while read sref noteblob obj; do
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
  done < <(_all_notes)
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
  repo-id)    shift; cmd_repo_id "$@" ;;
  zone)       shift; cmd_zone "$@" ;;
  export)     shift; cmd_export "$@" ;;
  import)     shift; cmd_import "$@" ;;
  sync-init)  shift; cmd_sync_init "$@" ;;
  compost)    shift; cmd_compost "$@" ;;
  migrate)    shift; cmd_migrate "$@" ;;
  doctor)     cmd_doctor ;;
  dump)       cmd_dump ;;
  prime)      cmd_prime ;;
  version|--version|-V) echo "mycelium $MYCELIUM_VERSION" ;;
  help|*)     usage ;;
esac
