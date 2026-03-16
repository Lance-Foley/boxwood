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
    .[] | select(.status == "active" and ((.path // .worktree_path // "") as $p | $p != "" and ($cwd | startswith($p)))) | .branch
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

  # Remove Solid Queue Puma plugin (causes macOS fork crash in worktrees)
  local puma_rb="$worktree_path/config/puma.rb"
  if [[ -f "$puma_rb" ]] && grep -q "plugin :solid_queue" "$puma_rb"; then
    sed -i '' '/plugin :solid_queue/d' "$puma_rb"
    success "Patched puma.rb: removed Solid Queue plugin"
  fi

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

  # Open RubyMine (always, even on resume)
  open -a "RubyMine" "$worktree_path" 2>/dev/null &

  # Resume existing tmux session if it exists
  if tmux has-session -t "$session_name" 2>/dev/null; then
    info "Reattaching to tmux session: $session_name"
    exec tmux attach -t "$session_name"
  fi

  # Create tmux session with split panes
  info "Starting tmux session: $session_name"
  tmux new-session -d -s "$session_name" -c "$worktree_path"
  tmux send-keys -t "$session_name" "PORT=$port bin/dev" Enter
  tmux split-window -h -t "$session_name" -c "$worktree_path"
  tmux send-keys -t "$session_name" "claude" Enter
  exec tmux attach -t "$session_name"
}

# ─── ws attach ──────────────────────────────────────────────────────────────

cmd_attach() {
  local branch="" pr_number="" new_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)     pr_number="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --new)    new_name="$2"; shift 2 ;;
      *)        error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  # Validate: exactly one mode
  local modes=0
  [[ -n "$pr_number" ]] && modes=$((modes + 1))
  [[ -n "$branch" ]] && modes=$((modes + 1))
  [[ -n "$new_name" ]] && modes=$((modes + 1))
  if [[ "$modes" -ne 1 ]]; then
    error "Provide exactly one of --pr, --branch, or --new."
    usage
    exit 1
  fi

  registry_prune

  # Resolve branch from PR (run gh from inside repo so it detects the remote)
  if [[ -n "$pr_number" ]]; then
    info "Resolving branch from PR #${pr_number}..."
    local pr_json
    pr_json=$(cd "$WESCOM_APP_PATH" && gh pr view "$pr_number" --json headRefName 2>/dev/null) || {
      error "PR #${pr_number} not found. Check the number and your gh auth status."
      exit 1
    }
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    success "PR #${pr_number} → branch: $branch"
  fi

  # Create new branch (fetch first so origin/main is current)
  if [[ -n "$new_name" ]]; then
    branch=$(slugify "$new_name")
    info "Creating new branch: $branch"
    git -C "$WESCOM_APP_PATH" fetch origin
  fi

  local dir_name
  dir_name=$(slugify "$branch")
  local worktree_path="$SESSIONS_DIR/$dir_name"
  local tmux_session="ws-$dir_name"

  # Check for slug collision with different branch (guard against null .path from old entries)
  local existing_branch
  existing_branch=$(jq -r --arg d "$dir_name" --arg b "$branch" \
    '.[] | select(.status == "active" and .branch != $b and ((.path // .worktree_path // "") | endswith("/"+$d))) | .branch' \
    "$SESSIONS_FILE" | head -1)
  if [[ -n "$existing_branch" ]]; then
    error "Directory name '$dir_name' is already used by branch '$existing_branch'."
    exit 1
  fi

  # Resume existing session
  if [[ -d "$worktree_path" ]]; then
    info "Existing worktree found at $worktree_path"

    # Handle database: check if it exists
    local db_name="wescomapp_dev_${dir_name//-/_}"
    db_name="${db_name:0:63}"
    if db_exists "$db_name"; then
      if confirm "Database '$db_name' exists. Drop and re-clone?"; then
        info "Fresh clone requested"
        db_drop "$db_name"
        db_clone "$db_name" || exit 1
      else
        info "Reusing existing database"
      fi
    else
      info "Database not found — creating fresh clone"
      db_clone "$db_name" || exit 1
    fi

    # Get port from registry or assign new one
    local port
    port=$(jq -r --arg b "$branch" '.[] | select(.branch == $b and .status == "active") | .port' "$SESSIONS_FILE" | head -1)
    if [[ -z "$port" || "$port" == "null" ]]; then
      port=$(next_port) || exit 1
      registry_add "$branch" "$db_name" "$port" "$worktree_path" "${pr_number:-null}"
    fi

    launch_tmux "$tmux_session" "$worktree_path" "$port"
    exit 0  # Safety: should not reach here (launch_tmux uses exec)
  fi

  # New session — create worktree, DB, env, memory
  info "Creating session for branch: $branch"
  git -C "$WESCOM_APP_PATH" fetch origin

  if [[ -n "$new_name" ]]; then
    # Branch off origin/main without mutating the main repo's checkout
    git -C "$WESCOM_APP_PATH" worktree add -b "$branch" "$worktree_path" origin/main
  else
    git -C "$WESCOM_APP_PATH" worktree add "$worktree_path" "origin/$branch"
  fi
  success "Worktree created at $worktree_path"

  local db_name="wescomapp_dev_${dir_name//-/_}"
  db_name="${db_name:0:63}"
  db_clone "$db_name" || exit 1

  local port
  port=$(next_port) || exit 1

  setup_session "$worktree_path" "$db_name" "$port" "$branch" "${pr_number:-}"
  registry_add "$branch" "$db_name" "$port" "$worktree_path" "${pr_number:-null}"

  header "Session Ready"
  echo -e "  ${BOLD}Branch:${NC}    $branch"
  echo -e "  ${BOLD}Database:${NC}  $db_name"
  echo -e "  ${BOLD}Port:${NC}      $port"
  echo -e "  ${BOLD}Path:${NC}      $worktree_path"
  echo ""

  launch_tmux "$tmux_session" "$worktree_path" "$port"
}

# ─── ws list ────────────────────────────────────────────────────────────────

cmd_list() {
  header "Active Sessions"

  local active
  active=$(jq '[.[] | select(.status == "active")]' "$SESSIONS_FILE")
  local count
  count=$(echo "$active" | jq 'length')

  if [[ "$count" == "0" ]]; then
    dim "  No active sessions."
    return
  fi

  printf "  ${BOLD}%-30s %-40s %-6s %s${NC}\n" "BRANCH" "DATABASE" "PORT" "STARTED"
  echo "  $(printf '%.0s─' {1..90})"

  echo "$active" | jq -r '.[] | "\(.branch)\t\(.db // .db_name // "?")\t\(.port // "?")\t\(.started)"' |
  while IFS=$'\t' read -r branch db port started; do
    printf "  %-30s %-40s %-6s %s\n" "${branch:0:28}" "${db:0:38}" "$port" "$started"
  done

  # Check for orphaned databases
  local session_dbs
  session_dbs=$(db_list_session_dbs)
  if [[ -n "$session_dbs" ]]; then
    local orphaned=""
    while IFS= read -r db; do
      if ! echo "$active" | jq -e --arg db "$db" '.[] | select((.db // .db_name) == $db)' > /dev/null 2>&1; then
        orphaned+="  $db\n"
      fi
    done <<< "$session_dbs"
    if [[ -n "$orphaned" ]]; then
      echo ""
      warn "Orphaned databases (no active session):"
      echo -e "$orphaned"
    fi
  fi
}

# ─── ws end ─────────────────────────────────────────────────────────────────

cmd_end() {
  local branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      -*)       error "Unknown option: $1"; exit 1 ;;
      *)        branch="$1"; shift ;;  # positional: ws end <branch>
    esac
  done

  # Detect from cwd if no branch specified
  if [[ -z "$branch" ]]; then
    branch=$(find_session_by_cwd "$(pwd)")
    if [[ -z "$branch" ]]; then
      error "Not in a session directory. Use --branch <name>."
      exit 1
    fi
  fi

  local session
  session=$(jq --arg b "$branch" '.[] | select(.branch == $b and .status == "active")' "$SESSIONS_FILE")
  if [[ -z "$session" ]]; then
    error "No active session for branch: $branch"
    exit 1
  fi

  local db_name worktree_path
  db_name=$(echo "$session" | jq -r '.db // .db_name')
  worktree_path=$(echo "$session" | jq -r '.path // .worktree_path')

  header "Ending session: $branch"

  # Show git status
  if [[ -d "$worktree_path" ]]; then
    local ahead
    ahead=$(git -C "$worktree_path" rev-list --count main..HEAD 2>/dev/null || echo "0")
    local dirty
    dirty=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    info "Commits ahead of main: $ahead"
    info "Uncommitted files: $dirty"
    echo ""
  fi

  # Push
  if confirm "Push branch to origin?"; then
    git -C "$worktree_path" push -u origin "$branch" 2>/dev/null && success "Branch pushed" || warn "Push failed"
    echo ""
  fi

  # Drop DB
  if confirm "Drop database ($db_name)?"; then
    db_drop "$db_name"
    echo ""
  fi

  # Remove worktree
  if confirm "Remove worktree ($worktree_path)?"; then
    if [[ "$(pwd)" == "$worktree_path"* ]]; then
      cd "$HOME"
    fi
    git -C "$WESCOM_APP_PATH" worktree remove --force "$worktree_path" 2>/dev/null
    git -C "$WESCOM_APP_PATH" worktree prune 2>/dev/null
    success "Worktree removed"
    echo ""
  fi

  # Mark ended in registry BEFORE killing tmux (in case we're running inside it)
  registry_end "$branch"
  success "Session ended: $branch"

  # Kill tmux (may terminate our own shell if running inside the session)
  local tmux_session="ws-$(slugify "$branch")"
  tmux kill-session -t "$tmux_session" 2>/dev/null && success "Tmux session killed" || true
}

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
