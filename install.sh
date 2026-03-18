#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "ws — WescomApp Session Tool Installer"
echo ""

# Check prerequisites
missing=()
for cmd in git docker jq gh tmux claude; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites:"
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      docker)  echo "  $cmd — Install OrbStack: brew install orbstack" ;;
      jq)      echo "  $cmd — brew install jq" ;;
      gh)      echo "  $cmd — brew install gh" ;;
      tmux)    echo "  $cmd — brew install tmux" ;;
      claude)  echo "  $cmd — npm install -g @anthropic-ai/claude-code" ;;
      *)       echo "  $cmd" ;;
    esac
  done
  echo ""
  echo "Install missing tools and re-run."
  exit 1
fi

# Validate gh auth
if ! gh auth status &>/dev/null; then
  echo "GitHub CLI is not authenticated. Run: gh auth login"
  exit 1
fi

# Validate Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "Docker daemon is not running. Start OrbStack (or Docker Desktop) and re-run."
  exit 1
fi

# Make ws executable
chmod +x "$SCRIPT_DIR/ws"

# Symlink
if [[ -w "/usr/local/bin" ]]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi
ln -sf "$SCRIPT_DIR/ws" "$INSTALL_DIR/ws"

echo "Installed ws to $INSTALL_DIR/ws"
echo ""
echo "Environment (add to shell profile if not already set):"
echo "  export WESCOM_APP_PATH=~/code/WescomApp          # default"
echo ""
echo "Next steps:"
echo "  1. ws rebuild                         # Build the base Docker image"
echo "  2. ws attach --new \"My first session\"  # Create your first session"
