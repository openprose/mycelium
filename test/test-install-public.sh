#!/usr/bin/env bash
# Public installer canary.
#
# This is intentionally separate from test/test.sh because it depends on the
# GitHub raw URL being reachable without auth. While the repo is private,
# this test is expected to fail. Once the repo is public, it should pass.
set -euo pipefail

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

RAW_INSTALLER_URL="https://raw.githubusercontent.com/openprose/mycelium/main/install.sh"
PREFIX_DIR="$TMPDIR/prefix"
TARGET="$PREFIX_DIR/bin/mycelium.sh"

echo ""
echo "=== Public Installer Canary ==="
echo "Fetching $RAW_INSTALLER_URL"

if ! curl -fsSL "$RAW_INSTALLER_URL" | PREFIX="$PREFIX_DIR" bash; then
  echo "✗ public raw installer is not reachable yet"
  echo "  expected while openprose/mycelium is private"
  exit 1
fi

if [[ ! -x "$TARGET" ]]; then
  echo "✗ installer ran but $TARGET was not created"
  exit 1
fi

if ! "$TARGET" help >/dev/null 2>&1; then
  echo "✗ installed mycelium.sh did not execute cleanly"
  exit 1
fi

echo "✓ public raw installer is reachable and working"
