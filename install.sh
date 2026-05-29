#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "boxwood — isolated containerized dev sessions (CLI: ws)"
echo ""

# Check prerequisites. gh is only needed for `ws attach --pr`, so it's optional.
missing=()
for cmd in git docker jq ruby tmux claude; do
  command -v "$cmd" &>/dev/null || missing+=("$cmd")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites:"
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      docker)  echo "  $cmd — Install OrbStack: brew install orbstack" ;;
      jq)      echo "  $cmd — brew install jq" ;;
      ruby)    echo "  $cmd — preinstalled on macOS, or: brew install ruby (used to parse .ws/config.yml)" ;;
      tmux)    echo "  $cmd — brew install tmux" ;;
      claude)  echo "  $cmd — npm install -g @anthropic-ai/claude-code" ;;
      *)       echo "  $cmd" ;;
    esac
  done
  echo ""
  echo "Install missing tools and re-run."
  exit 1
fi

# gh is optional (only for --pr); warn but don't block.
if ! command -v gh &>/dev/null; then
  echo "Note: gh not found — 'ws attach --pr' will be unavailable (brew install gh)."
elif ! gh auth status &>/dev/null; then
  echo "Note: gh is not authenticated — 'ws attach --pr' needs 'gh auth login'."
fi

# Validate Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "Docker daemon is not running. Start OrbStack (or Docker Desktop) and re-run."
  exit 1
fi

# Make ws executable + symlink onto PATH
chmod +x "$SCRIPT_DIR/ws"
if [[ -w "/usr/local/bin" ]]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi
ln -sf "$SCRIPT_DIR/ws" "$INSTALL_DIR/ws"

echo ""
echo "Installed ws to $INSTALL_DIR/ws"
echo ""
echo "Next steps — in any repo you want sessions for:"
echo "  1. cd /path/to/your-repo"
echo "  2. ws init                           # scaffold .ws/ (edit it to taste, commit it)"
echo "  3. ws rebuild                        # build the repo's base image"
echo "  4. ws attach --new \"My first session\"  # create your first session"
