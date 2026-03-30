#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/context-workflow.sh <path> [ref] [--history]

Recommended agent workflow for orienting on a file:
  1. exact note(s) on the current blob
  2. exact note(s) on parent dirs and root tree
  3. exact note(s) on the current commit
  4. optional file history via scripts/path-history.sh

This is a workflow recipe, not part of the mycelium core CLI.
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

all_refs() {
  local ref="$1"
  echo "$ref"
  git for-each-ref --format='%(refname:short)' "refs/notes/${ref}--slot--*" 2>/dev/null | sed 's|^notes/||' | sort -u
}

slot_display() {
  local ref="$1"
  if echo "$ref" | grep -q -- '--slot--'; then
    echo "[slot:$(echo "$ref" | sed 's/.*--slot--//')] "
  else
    echo ""
  fi
}

resolve_object() {
  local spec="$1"
  local oid
  oid=$(git rev-parse "$spec" 2>/dev/null || true)
  if [[ -n "$oid" && "$oid" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$oid"
  fi
}

show_object_notes() {
  local obj="$1" label="$2"
  local ref
  while read -r ref; do
    local note
    note=$(git notes --ref="$ref" show "$obj" 2>/dev/null || true)
    [[ -z "$note" ]] && continue
    local kind title prefix
    kind=$(note_header "$note" kind)
    title=$(note_header "$note" title)
    prefix=$(slot_display "$ref")
    echo "[$label] ${prefix}${title:-(untitled)} ($kind)"
    echo "$note"
    echo ""
  done < <(all_refs "$BASE_REF")
}

filepath=""
at="HEAD"
show_history=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --history) show_history=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$filepath" ]]; then
        filepath="$1"
      else
        at="$1"
      fi
      shift ;;
  esac
done

[[ -z "$filepath" ]] && { usage >&2; exit 1; }
BASE_REF=$(base_ref)

printf '=== workflow context: %s @ %s (%s) ===\n\n' "$filepath" "$at" "$BASE_REF"

blob=""
if [[ "$filepath" != "." ]]; then
  blob=$(resolve_object "$at:$filepath")
fi
if [[ -n "$blob" ]]; then
  show_object_notes "$blob" "exact"
elif [[ "$filepath" != "." ]]; then
  echo "(path does not resolve at $at: $filepath)"
  echo ""
fi

dir="$filepath"
while true; do
  dir=$(dirname "$dir")
  if [[ "$dir" == "." ]]; then
    tree=$(resolve_object "$at^{tree}")
    label="tree"
  else
    tree=$(resolve_object "$at:$dir")
    label="tree"
  fi
  [[ -n "${tree:-}" ]] && show_object_notes "$tree" "$label"
  [[ "$dir" == "." || "$dir" == "/" ]] && break
done

commit=$(git rev-parse "$at" 2>/dev/null || true)
[[ -n "$commit" ]] && show_object_notes "$commit" "commit"

while read -r iref; do
  [[ -z "$iref" ]] && continue
  iname=$(echo "$iref" | sed 's/.*--import--//')
  if [[ -n "$blob" ]]; then
    inote=$(git notes --ref="$iref" show "$blob" 2>/dev/null || true)
    if [[ -n "$inote" ]]; then
      ikind=$(note_header "$inote" kind)
      ititle=$(note_header "$inote" title)
      echo "[import:$iname] ${ititle:-(untitled)} ($ikind)"
      echo "$inote"
      echo ""
    fi
  fi
  inotelist=$(git notes --ref="$iref" list 2>/dev/null || true)
  while read -r inoteblob iobj; do
    [[ -z "$inoteblob" ]] && continue
    icontent=$(git cat-file -p "$inoteblob")
    if echo "$icontent" | grep -q '^edge targets-treepath treepath:\.$'; then
      ikind=$(note_header "$icontent" kind)
      ititle=$(note_header "$icontent" title)
      echo "[import:$iname] ${ititle:-(untitled)} ($ikind) — imported project-level"
      echo "$icontent"
      echo ""
    fi
  done <<< "$inotelist"
done < <(git for-each-ref --format='%(refname:short)' "refs/notes/${BASE_REF}--import--*" 2>/dev/null | grep -v -- '--import--_discovering$' | sed 's|^notes/||' | sort -u)

if [[ "$show_history" == "true" ]]; then
  echo "---"
  echo "Historical file notes:"
  "$(dirname "$0")/path-history.sh" "$filepath" "$at"
fi
