#!/bin/bash
# Install the ccc launcher: symlink into ~/.local/bin and copy the example
# config to ~/.claude/account-guard.json if one isn't already there.
#
# Run from the repo root:
#   bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.claude"
CONFIG_FILE="$CONFIG_DIR/account-guard.json"
EXAMPLE_FILE="$REPO_DIR/account-guard.example.json"

GREEN='\033[0;32m'
GOLD='\033[0;33m'
DIM='\033[0;90m'
NC='\033[0m'

mkdir -p "$BIN_DIR"
mkdir -p "$CONFIG_DIR"

# --- Symlink ccc into ~/.local/bin ---
LINK="$BIN_DIR/ccc"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$REPO_DIR/ccc" ]; then
  echo -e "${DIM}✓ Symlink already in place: $LINK${NC}"
elif [ -e "$LINK" ]; then
  echo "✗ $LINK already exists and is not the expected symlink."
  echo "  Move it aside, then re-run: bash install.sh"
  exit 1
else
  ln -s "$REPO_DIR/ccc" "$LINK"
  echo -e "${GREEN}✓${NC} Symlinked $REPO_DIR/ccc → $LINK"
fi

# --- Copy example config if user has none ---
if [ -f "$CONFIG_FILE" ]; then
  echo -e "${DIM}✓ Config already exists: $CONFIG_FILE (leaving alone)${NC}"
else
  cp "$EXAMPLE_FILE" "$CONFIG_FILE"
  echo -e "${GREEN}✓${NC} Copied example config to $CONFIG_FILE"
  echo -e "${GOLD}  → Edit it now: fill in your email(s) and repo folder matches.${NC}"
fi

# --- PATH check ---
case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo -e "${DIM}✓ $BIN_DIR is on your PATH${NC}"
    ;;
  *)
    echo ""
    echo -e "${GOLD}⚠${NC} $BIN_DIR is NOT on your PATH."
    echo "   Add to your shell rc (~/.zshrc or ~/.bashrc):"
    echo "     export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "   Then: source ~/.zshrc"
    ;;
esac

echo ""
echo -e "${GREEN}Install done.${NC} Next steps:"
echo "  1. Edit $CONFIG_FILE (emails + repo folder rules)"
echo "  2. Run: ccc --setup     (log in once per account)"
echo "  3. cd into any of your repos and run: ccc"
