#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/path-history.sh <path> [ref]

Walk git history for a path and print notes found on historical file blobs.
This leans on git's own history rather than mycelium-specific stale/renew state.
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

filepath="${1:-}"
at="${2:-HEAD}"
[[ -z "$filepath" ]] && { usage >&2; exit 1; }
BASE_REF=$(base_ref)

echo "=== file note history: $filepath @ $at ($BASE_REF) ==="
echo ""

seen_blobs=$(mktemp)
trap 'rm -f "$seen_blobs"' EXIT
found=false

while read -r commit; do
  [[ -z "$commit" ]] && continue
  blob=$(git rev-parse "$commit:$filepath" 2>/dev/null || true)
  [[ -z "$blob" ]] && continue
  if grep -qx "$blob" "$seen_blobs" 2>/dev/null; then
    continue
  fi
  echo "$blob" >> "$seen_blobs"
  while read -r ref; do
    note=$(git notes --ref="$ref" show "$blob" 2>/dev/null || true)
    [[ -z "$note" ]] && continue
    kind=$(note_header "$note" kind)
    title=$(note_header "$note" title)
    prefix=$(slot_display "$ref")
    printf '[history] %s%s (%s) — commit:%s blob:%s\n' "$prefix" "${title:-(untitled)}" "$kind" "${commit:0:12}" "${blob:0:12}"
    echo "$note"
    echo ""
    found=true
  done < <(all_refs "$BASE_REF")
done < <(git log --format='%H' -- "$at" -- "$filepath" 2>/dev/null || true)

if [[ "$found" == "false" ]]; then
  echo "(no historical file notes found)"
fi
