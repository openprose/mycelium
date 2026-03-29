#!/usr/bin/env bash
set -euo pipefail

# install.sh — mycelium installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/openprose/mycelium/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/openprose/mycelium/main/install.sh | PREFIX=/usr/local bash
#   VERSION=0.1.0 curl -fsSL https://raw.githubusercontent.com/openprose/mycelium/main/install.sh | bash
#   PREFIX=$HOME/.local ./install.sh
#
# Installs mycelium.sh to $PREFIX/bin/mycelium.sh.
# Default PREFIX is $HOME/.local so the installer works without sudo.
# Set VERSION to install a specific tagged release (e.g. VERSION=0.1.0).

PREFIX="${PREFIX:-$HOME/.local}"
INSTALL_DIR="$PREFIX/bin"
TARGET="$INSTALL_DIR/mycelium.sh"
MYCELIUM_REF="${VERSION:+v$VERSION}"
MYCELIUM_REF="${MYCELIUM_REF:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/openprose/mycelium/$MYCELIUM_REF}"

info() { printf '  %s\n' "$@"; }
error() { printf 'Error: %s\n' "$@" >&2; exit 1; }

check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "$1 is required but not found. Please install $1 first."
  fi
}

check_bash_version() {
  local bash_major
  bash_major="${BASH_VERSINFO[0]}"
  if [ "$bash_major" -lt 3 ]; then
    error "bash 3.2+ is required (found bash $bash_major). Please upgrade bash."
  fi
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
LOCAL_SCRIPT=""
if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  LOCAL_SCRIPT="$SCRIPT_DIR/mycelium.sh"
fi

info "Checking dependencies..."
check_bash_version
check_command git
if [ ! -f "$LOCAL_SCRIPT" ]; then
  check_command curl
fi
info "All dependencies satisfied."

info "Installing mycelium.sh to $TARGET"

if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR" 2>/dev/null || {
    error "Cannot create $INSTALL_DIR. Try: mkdir -p '$INSTALL_DIR'"
  }
fi

if [ ! -w "$INSTALL_DIR" ]; then
  error "Cannot write to $INSTALL_DIR. Re-run with a writable PREFIX or elevated permissions."
fi

if [ -f "$LOCAL_SCRIPT" ]; then
  info "Installing from local repo checkout..."
  cp "$LOCAL_SCRIPT" "$TARGET"
else
  info "Downloading from $REPO_BASE/mycelium.sh ..."
  curl -fsSL "$REPO_BASE/mycelium.sh" -o "$TARGET" || {
    error "Failed to download mycelium.sh from GitHub."
  }
fi

chmod +x "$TARGET"

# Stamp the version into the installed copy so non-git installs report correctly.
# The script uses git describe at runtime via a sentinel fallback.
if [ -n "$SCRIPT_DIR" ]; then
  INSTALL_VERSION="${VERSION:-$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo "unknown")}"
else
  INSTALL_VERSION="${VERSION:-unknown}"
fi
sed "s/__MYCELIUM_UNSTAMPED__/${INSTALL_VERSION}/" "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
chmod +x "$TARGET"

if [[ "$INSTALL_VERSION" == *-* && "$INSTALL_VERSION" != *unknown* ]]; then
  info "⚠ Installing pre-release version: $INSTALL_VERSION"
  info "  For stable releases, use VERSION=X.Y.Z or install from the main branch."
fi

if [ ! -x "$TARGET" ]; then
  error "Installation failed — $TARGET is not executable."
fi

if ! "$TARGET" help >/dev/null 2>&1; then
  error "Installation failed — installed script did not execute cleanly."
fi

echo ""
INSTALLED_VERSION=$( "$TARGET" --version 2>/dev/null || echo "unknown" )
echo "mycelium installed successfully! ($INSTALLED_VERSION)"
info "Location: $TARGET"

if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
  info "Add $INSTALL_DIR to your PATH if it is not already there."
fi

info "Quick start:"
info "  mycelium.sh note HEAD -k context -m \"First note.\""
info "  mycelium.sh read HEAD"
