#!/usr/bin/env bash
set -euo pipefail

# boxwood installer (CLI: ws) — macOS one-liner.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Lance-Foley/boxwood/main/install.sh)"
#
# Re-runnable and idempotent: every step is a no-op when already satisfied.
# Engine is Linux-clean; this installer is macOS-only for now.

REPO_URL="https://github.com/Lance-Foley/boxwood.git"
BOXWOOD_HOME="$HOME/.boxwood"

echo "boxwood — isolated containerized dev sessions (CLI: ws)"
echo ""

# --- (A) Locate ourselves: local clone vs. curl pipe --------------------------
# When piped via `bash -c "$(curl ...)"`, BASH_SOURCE may be "bash", "-", or
# otherwise unreadable, so guard everything before trusting it.
SCRIPT_DIR=""
SRC="${BASH_SOURCE[0]:-}"
if [[ -n "$SRC" && -f "$SRC" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SRC")" && pwd)" || SCRIPT_DIR=""
fi

# --- (B) Require macOS ---------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "boxwood's engine is Linux-clean, but this installer is macOS-only for now."
  echo "On Linux, install the deps yourself (git docker tmux jq yq), then symlink"
  echo "the 'ws' script from a clone of $REPO_URL onto your PATH."
  exit 0
fi

# --- (C) Ensure Homebrew -------------------------------------------------------
if ! command -v brew &>/dev/null; then
  echo "Homebrew not found — bootstrapping it (you may be prompted for your password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Put brew on PATH for the rest of this script (Apple silicon vs. Intel).
if ! command -v brew &>/dev/null; then
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_bin" ]]; then
      eval "$("$brew_bin" shellenv)"
      break
    fi
  done
fi

if ! command -v brew &>/dev/null; then
  echo "Homebrew still not on PATH after install. Open a new terminal and re-run, or"
  echo "add brew to your PATH manually, then re-run this installer."
  exit 1
fi

# --- (D) Required CLI deps (idempotent: only install what's missing) -----------
# yq here is mikefarah's Go implementation, which `brew install yq` provides.
for pkg in git tmux jq yq gh; do
  if ! command -v "$pkg" &>/dev/null; then
    echo "Installing $pkg..."
    brew install "$pkg"
  fi
done

# --- (E) Docker (OrbStack) — install if missing; don't assume it's running -----
if ! command -v docker &>/dev/null; then
  echo "Installing OrbStack (provides docker)..."
  brew install --cask orbstack
fi

# --- (F) Obtain the boxwood source --------------------------------------------
INSTALL_SRC=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/ws" ]]; then
  # Running from a local clone — use it in place.
  INSTALL_SRC="$SCRIPT_DIR"
else
  # Piped install — clone (or update) into ~/.boxwood.
  if [[ -d "$BOXWOOD_HOME/.git" ]]; then
    echo "Updating existing boxwood clone in $BOXWOOD_HOME..."
    git -C "$BOXWOOD_HOME" pull --ff-only || \
      echo "  Could not fast-forward $BOXWOOD_HOME — keeping the existing checkout."
  else
    echo "Cloning boxwood into $BOXWOOD_HOME..."
    git clone "$REPO_URL" "$BOXWOOD_HOME"
  fi
  INSTALL_SRC="$BOXWOOD_HOME"
fi

if [[ ! -f "$INSTALL_SRC/ws" ]]; then
  echo "Could not find the 'ws' script in $INSTALL_SRC — aborting."
  exit 1
fi

# --- (G) Symlink 'ws' onto PATH -----------------------------------------------
chmod +x "$INSTALL_SRC/ws"
if [[ -w "/usr/local/bin" ]]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi
ln -sf "$INSTALL_SRC/ws" "$INSTALL_DIR/ws"
echo "Installed ws to $INSTALL_DIR/ws"

# Warn if ~/.local/bin isn't on PATH so `ws` won't be found.
if [[ "$INSTALL_DIR" == "$HOME/.local/bin" ]]; then
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) : ;;
    *)
      echo "Warning: $INSTALL_DIR is not on your PATH. Add this to your shell profile:"
      echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac
fi

# --- (H) Scaffold per-user prefs (only if absent) ------------------------------
mkdir -p "$HOME/.ws"
if [[ ! -f "$HOME/.ws/config.yml" ]]; then
  cat > "$HOME/.ws/config.yml" <<'EOF'
# ~/.ws/config.yml — boxwood per-user preferences.
# Applies to every repo; never committed. Remove a key to use its default.
editor: nvim              # in-tmux editor; falls back to $EDITOR, then nvim
gui_editor:               # external GUI editor opened on the worktree, e.g. RubyMine or "Visual Studio Code". Empty = none.
assistant:
  command: claude         # AI assistant in the top-right pane. Empty = plain shell.
  skip_permissions: true  # launch Claude with --dangerously-skip-permissions
EOF
  echo "Wrote per-user preferences to $HOME/.ws/config.yml"
fi

# --- (I) Interactive tail (only when stdin is a tty) ---------------------------
if [[ -t 0 ]]; then
  # Docker: try to start OrbStack (or Docker Desktop) and wait for the daemon.
  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    echo "Docker is installed but not running — trying to start it..."
    open -a OrbStack 2>/dev/null || open -a Docker 2>/dev/null || \
      echo "  Could not auto-start a Docker app; start OrbStack/Docker manually."
    printf "Waiting for the Docker daemon"
    for _ in $(seq 1 30); do
      if docker info &>/dev/null; then break; fi
      printf "."
      sleep 2
    done
    echo ""
    if docker info &>/dev/null; then
      echo "Docker is up."
    else
      echo "Docker still isn't responding. Start OrbStack (or Docker Desktop) and re-run."
    fi
  fi

  # gh auth: prompt to log in if not authenticated (optional — only for --pr).
  if command -v gh &>/dev/null && ! gh auth status &>/dev/null; then
    echo "GitHub CLI (gh) is not authenticated — needed only for 'ws attach --pr'."
    printf "Run 'gh auth login' now? [y/N] "
    read -r reply || reply=""
    case "$reply" in
      [Yy]*) gh auth login || echo "  gh auth login did not complete; run it later." ;;
      *)     echo "  Skipped. Run 'gh auth login' later if you want --pr support." ;;
    esac
  fi

  # claude: optional assistant pane. Offer to install via npm if available.
  if ! command -v claude &>/dev/null; then
    echo "Claude Code CLI ('claude') is not installed — used for the assistant pane (optional)."
    if command -v npm &>/dev/null; then
      printf "Install it now with 'npm install -g @anthropic-ai/claude-code'? [y/N] "
      read -r reply || reply=""
      case "$reply" in
        [Yy]*) npm install -g @anthropic-ai/claude-code || \
                 echo "  Install failed; see https://claude.com/claude-code" ;;
        *)     echo "  Skipped. Install later: see https://claude.com/claude-code" ;;
      esac
    else
      echo "  npm not found — install Claude Code from https://claude.com/claude-code"
    fi
  fi
else
  # Non-interactive (piped): print the same checks as manual next steps.
  echo ""
  echo "Manual follow-ups (run these yourself):"
  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    echo "  - Start Docker: open -a OrbStack   (or 'open -a Docker'), then wait for it."
  fi
  if command -v gh &>/dev/null && ! gh auth status &>/dev/null; then
    echo "  - Authenticate GitHub CLI (only for 'ws attach --pr'): gh auth login"
  fi
  if ! command -v claude &>/dev/null; then
    echo "  - Install the optional assistant: npm install -g @anthropic-ai/claude-code"
    echo "    (or see https://claude.com/claude-code)"
  fi
fi

# --- (K) Next steps ------------------------------------------------------------
echo ""
echo "Next steps — in any repo you want sessions for:"
echo "  1. cd /path/to/your-repo"
echo "  2. ws init                              # scaffold .ws/ (edit to taste, commit it)"
echo "  3. ws rebuild                           # build the repo's base image"
echo "  4. ws attach --new \"My first session\"   # create your first session"
