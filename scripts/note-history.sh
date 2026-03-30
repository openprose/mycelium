#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/note-history.sh <target>

Show git-native note history for the current notes ref.
This is the recommended replacement for `supersedes` chains.
EOF
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

resolve_target() {
  local target="$1"
  local at="${2:-HEAD}"
  if [[ "$target" == "." ]]; then
    oid=$(git rev-parse "$at^{tree}" 2>/dev/null) || return 1
    echo "$oid"
    return
  fi
  if [[ -e "$target" ]] || git rev-parse --verify "$at:$target" >/dev/null 2>&1; then
    oid=$(git rev-parse "$at:$target" 2>/dev/null) || return 1
    echo "$oid"
    return
  fi
  git rev-parse --verify "$target" 2>/dev/null
}

target="${1:-}"
[[ -z "$target" ]] && { usage >&2; exit 1; }
BASE_REF=$(base_ref)
oid=$(resolve_target "$target") || { echo "Error: cannot resolve '$target'" >&2; exit 1; }
fanout="${oid:0:2}/${oid:2}"

echo "=== note history: $target ($oid) on refs/notes/$BASE_REF ==="
echo ""
git log -p "refs/notes/$BASE_REF" -- "$oid" "$fanout"
