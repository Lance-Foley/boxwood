#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "ws — WescomApp Session Tool Installer"
echo ""

# Check prerequisites
missing=()
for cmd in git psql createdb jq gh claude; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "⚠ Missing prerequisites:"
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      jq)     echo "  $cmd — brew install jq" ;;
      gh)     echo "  $cmd — brew install gh" ;;
      claude) echo "  $cmd — npm install -g @anthropic-ai/claude-code" ;;
      psql|createdb) echo "  $cmd — brew install postgresql" ;;
      *)      echo "  $cmd" ;;
    esac
  done
  echo ""
  echo "Install missing tools and re-run this script."
  exit 1
fi

# Make ws executable
chmod +x "$SCRIPT_DIR/ws"

# Symlink — try /usr/local/bin, fall back to ~/.local/bin
if [[ -w "/usr/local/bin" ]]; then
  INSTALL_DIR="/usr/local/bin"
  ln -sf "$SCRIPT_DIR/ws" "$INSTALL_DIR/ws"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
  ln -sf "$SCRIPT_DIR/ws" "$INSTALL_DIR/ws"
  # Check if it's in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -q "$INSTALL_DIR"; then
    echo ""
    echo "⚠ Add to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
fi

echo "✓ ws installed to $INSTALL_DIR/ws"
echo ""
echo "Setup:"
echo "  export NOTION_API_KEY=\"secret_...\"    # Add to your shell profile"
echo "  export WESCOM_APP_PATH=~/code/WescomApp  # Default, adjust if needed"
echo ""
echo "Run: ws new"
