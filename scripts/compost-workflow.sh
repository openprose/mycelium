#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/compost-workflow.sh [path|oid] [--compost|--renew|--dry-run|--report] [--slot <name>]

Explicit stale/renew workflow for repositories that want one.
This lives at the workflow-script layer rather than the core mycelium CLI.
EOF
}

note_header() {
  echo "$1" | grep "^$2 " | head -1 | sed "s/^$2 //" || true
}

base_ref() {
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
  if [[ -n "${MYCELIUM_REF:-}" ]]; then
    echo "$MYCELIUM_REF"
  elif [[ -f "$git_dir/mycelium-branch" ]]; then
    cat "$git_dir/mycelium-branch"
  else
    echo "mycelium"
  fi
}

validate_slot() {
  local slot="$1"
  [[ -z "$slot" ]] && return 0
  if echo "$slot" | grep -qE '^(main|default)$'; then
    echo "Error: '$slot' is a reserved slot name" >&2
    return 1
  fi
  if echo "$slot" | grep -q -- '--slot--'; then
    echo "Error: slot name cannot contain '--slot--'" >&2
    return 1
  fi
  if ! git check-ref-format "refs/notes/test--slot--$slot" >/dev/null 2>&1; then
    echo "Error: '$slot' is not a valid slot name" >&2
    return 1
  fi
}

slot_ref() {
  local base_ref="$1" slot="${2:-}"
  if [[ -z "$slot" ]]; then
    echo "$base_ref"
  else
    echo "${base_ref}--slot--${slot}"
  fi
}

slot_name_from_ref() {
  local ref="$1"
  if echo "$ref" | grep -q -- '--slot--'; then
    echo "$ref" | sed 's/.*--slot--//'
  else
    echo "default"
  fi
}

slot_display() {
  local ref="$1"
  local name
  name=$(slot_name_from_ref "$ref")
  if [[ "$name" != "default" ]]; then
    echo "[slot:$name] "
  else
    echo ""
  fi
}

assert_writable_ref() {
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

all_slot_refs() {
  local ref="$1"
  echo "$ref"
  git for-each-ref --format='%(refname:short)' "refs/notes/${ref}--slot--*" 2>/dev/null | \
    sed 's|^notes/||' | sort -u
}

all_notes() {
  local base_ref="$1"
  while read -r sref; do
    git notes --ref="$sref" list 2>/dev/null | while read -r noteblob obj; do
      [[ -z "$noteblob" ]] && continue
      echo "$sref $noteblob $obj"
    done
  done < <(all_slot_refs "$base_ref")
}

compost_note() {
  local obj="$1" cref="$2"
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

renew_note() {
  local obj="$1" rref="$2"
  local content
  content=$(git notes --ref="$rref" show "$obj" 2>/dev/null || true)
  [[ -z "$content" ]] && { echo "Error: no note on $obj in $rref" >&2; return 1; }

  local note_path
  note_path=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
  [[ -z "$note_path" ]] && note_path=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')
  [[ -z "$note_path" ]] && { echo "Error: note has no path edge, cannot renew" >&2; return 1; }

  local current_oid
  if [[ "$note_path" == "." ]]; then
    current_oid=$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  else
    current_oid=$(git rev-parse "HEAD:$note_path" 2>/dev/null || true)
  fi
  [[ -z "$current_oid" ]] && { echo "Error: path no longer exists: $note_path" >&2; return 1; }

  local current_type
  current_type=$(git cat-file -t "$current_oid" 2>/dev/null)

  local existing_on_new
  existing_on_new=$(git notes --ref="$rref" list "$current_oid" 2>/dev/null | cut -d' ' -f1 || true)
  if [[ -n "$existing_on_new" ]]; then
    echo "Error: current version already has a note in $rref" >&2
    return 1
  fi

  local new_content
  new_content=$(echo "$content" | sed "s|^edge applies-to [a-z]*:.*|edge applies-to $current_type:$current_oid|")
  git notes --ref="$rref" add -f -m "$new_content" "$current_oid" 2>/dev/null
  compost_note "$obj" "$rref"
  echo "$current_oid"
}

collect_stale() {
  local base_ref="$1" target="${2:-.}" filter_slot="${3:-}"
  local notelist
  notelist=$(all_notes "$base_ref")
  [[ -z "$notelist" ]] && return

  while read -r sref noteblob obj; do
    [[ -z "$sref" ]] && continue

    if [[ -n "$filter_slot" ]]; then
      local expected_ref
      expected_ref=$(slot_ref "$base_ref" "$filter_slot")
      [[ "$sref" != "$expected_ref" ]] && continue
    fi

    local content note_status
    content=$(git cat-file -p "$noteblob")
    note_status=$(note_header "$content" status)
    [[ "$note_status" == "composted" ]] && continue

    local target_path target_treepath note_target="" is_stale=false
    target_path=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
    target_treepath=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')

    if [[ -n "$target_path" ]]; then
      note_target="$target_path"
      local current_blob
      current_blob=$(git rev-parse "HEAD:$target_path" 2>/dev/null || true)
      if [[ -z "$current_blob" || "$current_blob" != "$obj" ]]; then
        is_stale=true
      fi
    elif [[ -n "$target_treepath" && "$target_treepath" != "." ]]; then
      note_target="$target_treepath"
      local current_tree
      current_tree=$(git rev-parse "HEAD:$target_treepath" 2>/dev/null || true)
      if [[ -z "$current_tree" || "$current_tree" != "$obj" ]]; then
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
      local kind title
      kind=$(note_header "$content" kind)
      title=$(note_header "$content" title)
      printf '%s\t%s\t%s\t%s\t%s\n' "$sref" "$obj" "$note_target" "$kind" "${title:-(untitled)}"
    fi
  done <<< "$notelist"
}

resolve_oid_for_workflow() {
  local base_ref="$1" short="$2" slot="$3"
  local matches=()
  while read -r sref; do
    local full
    full=$(git notes --ref="$sref" list 2>/dev/null | awk -v t="$short" '$2 ~ "^"t {print $2; exit}')
    if [[ -n "$full" ]]; then
      matches+=("$sref:$full")
    fi
  done < <(all_slot_refs "$base_ref")

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Error: no note on object matching $short" >&2
    return 1
  fi

  if [[ -n "$slot" ]]; then
    local slot_ref_value
    slot_ref_value=$(slot_ref "$base_ref" "$slot")
    local m mref moid
    for m in "${matches[@]}"; do
      mref="${m%%:*}"
      moid="${m#*:}"
      if [[ "$mref" == "$slot_ref_value" ]]; then
        echo "$mref $moid"
        return 0
      fi
    done
    echo "Error: no note on $short in slot '$slot'" >&2
    return 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Error: ambiguous — $short has notes in multiple slots:" >&2
    local m slot_name
    for m in "${matches[@]}"; do
      slot_name=$(slot_name_from_ref "${m%%:*}")
      echo "  ${slot_name:-default}" >&2
    done
    echo "Use --slot to specify which one" >&2
    return 1
  fi

  echo "${matches[0]%%:*} ${matches[0]#*:}"
}

BASE_REF=$(base_ref)
target=""
action=""
dry_run=false
slot=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --report) action="report"; shift ;;
    --compost) action="compost"; shift ;;
    --renew) action="renew"; shift ;;
    --slot) slot="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) target="$1"; shift ;;
  esac
done

target="${target:-.}"
validate_slot "$slot" || exit 1
assert_writable_ref "$BASE_REF" || exit 1

if [[ "$action" == "compost" && "$target" != "." ]]; then
  if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
    resolved_oid=$(resolve_oid_for_workflow "$BASE_REF" "$target" "$slot") || exit 1
    cref="${resolved_oid%% *}"
    full_oid="${resolved_oid#* }"
    compost_note "$full_oid" "$cref"
    content=$(git notes --ref="$cref" show "$full_oid" 2>/dev/null || true)
    kind=$(note_header "$content" kind)
    title=$(note_header "$content" title)
    echo "✓ composted [$kind] ${title:-(untitled)}"
    exit 0
  fi

  found=false
  while IFS=$'\t' read -r sref obj note_path kind title; do
    [[ -z "$sref" ]] && continue
    compost_note "$obj" "$sref"
    slot_label=$(slot_display "$sref")
    echo "✓ composted ${slot_label}[$kind] $title — $note_path"
    found=true
  done < <(collect_stale "$BASE_REF" "$target" "$slot")
  if [[ "$found" == "false" ]]; then
    echo "No stale notes under $target"
  fi
  exit 0
fi

if [[ "$action" == "renew" && "$target" != "." ]]; then
  if [[ "$target" =~ ^[0-9a-f]{6,}$ ]]; then
    resolved_oid=$(resolve_oid_for_workflow "$BASE_REF" "$target" "$slot") || exit 1
    rref="${resolved_oid%% *}"
    full_oid="${resolved_oid#* }"
    new_oid=$(renew_note "$full_oid" "$rref") || exit 1
    content=$(git notes --ref="$rref" show "$new_oid" 2>/dev/null || true)
    kind=$(note_header "$content" kind)
    title=$(note_header "$content" title)
    echo "✓ renewed [$kind] ${title:-(untitled)} → ${new_oid:0:12}"
    exit 0
  fi

  found=false
  while IFS=$'\t' read -r sref obj note_path kind title; do
    [[ -z "$sref" ]] && continue
    new_oid=$(renew_note "$obj" "$sref") && {
      slot_label=$(slot_display "$sref")
      echo "✓ renewed ${slot_label}[$kind] $title — $note_path → ${new_oid:0:12}"
      found=true
    }
  done < <(collect_stale "$BASE_REF" "$target" "$slot")
  if [[ "$found" == "false" ]]; then
    echo "No stale notes under $target"
  fi
  exit 0
fi

if [[ "$action" == "report" ]]; then
  stale_count=0
  composted_count=0
  notelist=$(all_notes "$BASE_REF")
  if [[ -z "$notelist" ]]; then
    echo "mycelium: 0 stale, 0 composted"
    exit 0
  fi
  while read -r sref noteblob obj; do
    [[ -z "$sref" ]] && continue
    content=$(git cat-file -p "$noteblob")
    ns=$(note_header "$content" status)
    if [[ "$ns" == "composted" ]]; then
      composted_count=$((composted_count + 1))
    else
      tp=$(echo "$content" | awk '/^edge targets-path /{sub(/^edge targets-path path:/,""); print; exit}')
      tt=$(echo "$content" | awk '/^edge targets-treepath /{sub(/^edge targets-treepath treepath:/,""); print; exit}')
      if [[ -n "$tp" ]]; then
        cb=$(git rev-parse "HEAD:$tp" 2>/dev/null || true)
        if [[ -z "$cb" || "$cb" != "$obj" ]]; then
          stale_count=$((stale_count + 1))
        fi
      elif [[ -n "$tt" && "$tt" != "." ]]; then
        ct=$(git rev-parse "HEAD:$tt" 2>/dev/null || true)
        if [[ -z "$ct" || "$ct" != "$obj" ]]; then
          stale_count=$((stale_count + 1))
        fi
      fi
    fi
  done <<< "$notelist"
  echo "mycelium: $stale_count stale, $composted_count composted"
  exit 0
fi

stale_lines=$(collect_stale "$BASE_REF" "$target" "$slot")
if [[ -z "$stale_lines" ]]; then
  echo "No stale notes${target:+ under $target}."
  exit 0
fi
stale_count=$(echo "$stale_lines" | wc -l)

echo "$stale_count stale note(s)${target:+ under $target}:"
echo ""

while IFS=$'\t' read -r sref obj note_path kind title; do
  [[ -z "$sref" ]] && continue
  slot_label=$(slot_display "$sref")
  echo "  ${slot_label}[$kind] ${title} — $note_path (${obj:0:12})"

  [[ "$dry_run" == "true" ]] && continue

  content=$(git notes --ref="$sref" show "$obj" 2>/dev/null)
  echo ""
  echo "$content" | sed 's/^/    /'
  echo ""
  echo "  (c)ompost  — mark as composted, hide from workflow output"
  echo "  (r)enew    — re-attach to current version"
  echo "  (s)kip     — leave as-is"
  echo "  (q)uit     — stop composting"

  while true; do
    if [[ -t 0 ]]; then
      read -r -p "  [c/r/s/q] " choice </dev/tty
    else
      read -r choice || choice="q"
    fi
    case "$choice" in
      c|compost)
        compost_note "$obj" "$sref"
        echo "  ✓ composted"
        echo ""
        break ;;
      r|renew)
        new_oid=$(renew_note "$obj" "$sref") && echo "  ✓ renewed → ${new_oid:0:12}" || true
        echo ""
        break ;;
      s|skip)
        echo "  — skipped"
        echo ""
        break ;;
      q|quit)
        echo "  — stopping"
        exit 0 ;;
      *)
        echo "  ? c/r/s/q" ;;
    esac
  done
done <<< "$stale_lines"
