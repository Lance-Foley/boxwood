#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks to find real script dir
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# Source library files
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/database.sh"

# Defaults
: "${WESCOM_APP_PATH:=$HOME/code/WescomApp}"
: "${PG_USER:=$(whoami)}"
: "${PG_BASE_DB:=wescom_app_development}"
: "${SESSIONS_FILE:=$HOME/.wescom-sessions.json}"
: "${SESSIONS_DIR:=$HOME/code/wescom-sessions}"

# Ensure sessions file exists and sessions dir exists
[[ -f "$SESSIONS_FILE" ]] || echo '[]' > "$SESSIONS_FILE"
mkdir -p "$SESSIONS_DIR"

# ─── Helpers ────────────────────────────────────────────────────────────────

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's|/|-|g; s/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50
}

registry_add() {
  local branch="$1" db="$2" port="$3" path="$4" pr="${5:-null}"
  local now
  now=$(date +"%Y-%m-%d %H:%M")
  local tmp
  tmp=$(mktemp)
  jq --arg b "$branch" --arg d "$db" --argjson p "$port" \
     --arg pt "$path" --argjson pr "$pr" --arg s "$now" \
     '. + [{branch:$b, db:$d, port:$p, path:$pt, pr:$pr, started:$s, status:"active"}]' \
     "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

registry_end() {
  local branch="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg b "$branch" \
     'map(if .branch == $b then .status = "ended" else . end)' \
     "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

registry_prune() {
  local cutoff
  cutoff=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d")
  local tmp
  tmp=$(mktemp)
  jq --arg c "$cutoff" \
     '[.[] | select(.status == "active" or .started > $c)]' \
     "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

next_port() {
  local used
  used=$(jq -r '.[] | select(.status == "active") | .port' "$SESSIONS_FILE")
  for p in 3000 3001 3002 3003 3004; do
    if ! echo "$used" | grep -qw "$p"; then
      echo "$p"
      return 0
    fi
  done
  error "All session ports (3000-3004) are in use. Run 'ws end' to free a session."
  return 1
}

find_session_by_cwd() {
  local cwd="$1"
  jq -r --arg cwd "$cwd" '
    .[] | select(.status == "active" and ($cwd | startswith(.path))) | .branch
  ' "$SESSIONS_FILE" | head -1
}

setup_session() {
  local worktree_path="$1" db_name="$2" port="$3" branch="$4" pr="${5:-}"

  # Copy .env and append overrides
  if [[ -f "$WESCOM_APP_PATH/.env" ]]; then
    cp "$WESCOM_APP_PATH/.env" "$worktree_path/.env"
  else
    touch "$worktree_path/.env"
  fi
  cat >> "$worktree_path/.env" <<EOF
DATABASE_URL=postgres://localhost/$db_name
PORT=$port
SOLID_QUEUE_IN_PUMA=false
WEB_CONCURRENCY=0
EOF

  # Session memory directory
  mkdir -p "$worktree_path/.session/memory"

  # Append session context to CLAUDE.md
  cat >> "$worktree_path/CLAUDE.md" <<EOF

# Session Context
- Branch: $branch
- Database: $db_name
- Port: $port
${pr:+- PR: #$pr}

This is an isolated worktree session. Your database is separate
from the main development database.

Use .session/memory/ to track decisions, progress, and context
about this work. Store session notes, decision logs, and progress
updates in .session/memory/ so they persist across conversations.
EOF

  # Git excludes so session files don't show as dirty
  # Worktrees use a .git file (not directory), so resolve the real git dir
  local git_dir
  git_dir=$(git -C "$worktree_path" rev-parse --git-dir)
  mkdir -p "$git_dir/info"
  echo "CLAUDE.md" >> "$git_dir/info/exclude"
  echo ".session/" >> "$git_dir/info/exclude"
  echo ".env" >> "$git_dir/info/exclude"
}

launch_tmux() {
  local session_name="$1" worktree_path="$2" port="$3"

  # Resume existing tmux session if it exists
  if tmux has-session -t "$session_name" 2>/dev/null; then
    info "Reattaching to tmux session: $session_name"
    exec tmux attach -t "$session_name"
  fi

  # Open RubyMine
  open -a "RubyMine" "$worktree_path" 2>/dev/null &

  # Create tmux session with split panes
  info "Starting tmux session: $session_name"
  tmux new-session -d -s "$session_name" -c "$worktree_path"
  tmux send-keys -t "$session_name" "PORT=$port bin/dev" Enter
  tmux split-window -h -t "$session_name" -c "$worktree_path"
  tmux send-keys -t "$session_name" "claude" Enter
  exec tmux attach -t "$session_name"
}

# ─── Commands (cmd_attach, cmd_list, cmd_end will be added later) ────────────

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}ws${NC} — WescomApp Session Manager

${BOLD}Usage:${NC}
  ws attach --pr <number>            Attach to existing PR
  ws attach --branch <name>          Attach to existing branch
  ws attach --new "description"      Create new branch + session
  ws list                            Show active sessions
  ws end [--branch <name>]           Clean up a session

${BOLD}Environment:${NC}
  WESCOM_APP_PATH    Path to WescomApp repo (default: ~/code/WescomApp)
  PG_USER            PostgreSQL user (default: \$(whoami))
  PG_BASE_DB         Source database to clone (default: wescom_app_development)
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  attach) shift; cmd_attach "$@" ;;
  list)   cmd_list ;;
  end)    shift; cmd_end "$@" ;;
  -h|--help|help) usage ;;
  *)      usage ;;
esac
