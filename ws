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
source "$SCRIPT_DIR/lib/docker.sh"

# Defaults
: "${WESCOM_APP_PATH:=$HOME/code/WescomApp}"
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
  for p in $(seq 3001 3010); do
    if ! echo "$used" | grep -qw "$p"; then
      echo "$p"
      return 0
    fi
  done
  error "All session ports (3001-3010) are in use. Run 'ws end' to free a session."
  return 1
}

find_session_by_cwd() {
  local cwd="$1"
  jq -r --arg cwd "$cwd" '
    .[] | select(.status == "active" and ((.path // .worktree_path // "") as $p | $p != "" and ($cwd | startswith($p)))) | .branch
  ' "$SESSIONS_FILE" | head -1
}

setup_worktree() {
  local worktree_path="$1" branch="$2" port="$3" pr="${4:-}"

  # Copy .env from main repo (secrets, API keys)
  if [[ -f "$WESCOM_APP_PATH/.env" ]]; then
    cp "$WESCOM_APP_PATH/.env" "$worktree_path/.env"
  else
    touch "$worktree_path/.env"
  fi

  # Session memory directory
  mkdir -p "$worktree_path/.session/memory"

  # Append session context to CLAUDE.md
  cat >> "$worktree_path/CLAUDE.md" <<EOF

# Session Context
- Branch: $branch
- Port: $port (http://localhost:$port)
${pr:+- PR: #$pr}

This is an isolated worktree session running in Docker containers.
Run commands inside the container via: ws exec <command>
e.g. ws exec rails console

Use .session/memory/ to track decisions, progress, and context
about this work.
EOF

  # Git excludes so session files don't show as dirty
  local git_dir
  git_dir=$(git -C "$worktree_path" rev-parse --git-dir)
  mkdir -p "$git_dir/info"
  for f in CLAUDE.md .session/ .env docker-compose.yml; do
    grep -qxF "$f" "$git_dir/info/exclude" 2>/dev/null || echo "$f" >> "$git_dir/info/exclude"
  done
}

launch_tmux() {
  local session_name="$1" worktree_path="$2" project="$3"

  # Open RubyMine
  open -a "RubyMine" "$worktree_path" 2>/dev/null &

  # Resume existing tmux session if it exists
  if tmux has-session -t "$session_name" 2>/dev/null; then
    info "Reattaching to tmux session: $session_name"
    if [[ -n "${TMUX:-}" ]]; then
      exec tmux switch-client -t "$session_name"
    else
      exec tmux attach -t "$session_name"
    fi
  fi

  # Create tmux session with split panes
  info "Starting tmux session: $session_name"
  tmux new-session -d -s "$session_name" -c "$worktree_path"

  # Pane 0 (top-left): container logs
  tmux send-keys -t "$session_name" "docker compose -p $project -f $worktree_path/docker-compose.yml logs -f app worker" Enter

  # Pane 1 (right): Claude Code on host
  tmux split-window -h -t "$session_name" -c "$worktree_path"
  tmux send-keys -t "$session_name" "claude --dangerously-skip-permissions" Enter

  # Pane 2 (bottom-left): clean terminal in worktree (use 'ws exec' for container commands)
  tmux select-pane -t "$session_name:.0"
  tmux split-window -v -t "$session_name" -c "$worktree_path" -l 30%

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$session_name"
  else
    exec tmux attach -t "$session_name"
  fi
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

  # Check base image exists
  if ! image_exists; then
    error "Base image not found. Run 'ws rebuild' first."
    exit 1
  fi

  # Check latest.dump exists
  if [[ ! -f "$WESCOM_APP_PATH/latest.dump" ]]; then
    error "No latest.dump found at $WESCOM_APP_PATH/latest.dump"
    error "Download a production dump before creating sessions."
    exit 1
  fi

  registry_prune

  # Resolve branch from PR
  if [[ -n "$pr_number" ]]; then
    info "Resolving branch from PR #${pr_number}..."
    local pr_json
    pr_json=$(cd "$WESCOM_APP_PATH" && gh pr view "$pr_number" --json headRefName 2>/dev/null) || {
      error "PR #${pr_number} not found."
      exit 1
    }
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    success "PR #${pr_number} → branch: $branch"
  fi

  # Create new branch
  if [[ -n "$new_name" ]]; then
    branch=$(slugify "$new_name")
    info "Creating new branch: $branch"
    git -C "$WESCOM_APP_PATH" fetch origin
  fi

  local dir_name
  dir_name=$(slugify "$branch")
  local worktree_path="$SESSIONS_DIR/$dir_name"
  local tmux_session="ws-$dir_name"
  local project
  project=$(compose_project_name "$dir_name")

  # Check for slug collision
  local existing_branch
  existing_branch=$(jq -r --arg d "$dir_name" --arg b "$branch" \
    '.[] | select(.status == "active" and .branch != $b and ((.path // "") | endswith("/"+$d))) | .branch' \
    "$SESSIONS_FILE" | head -1)
  if [[ -n "$existing_branch" ]]; then
    error "Directory name '$dir_name' is already used by branch '$existing_branch'."
    exit 1
  fi

  # Resume or restart existing session
  if [[ -d "$worktree_path" ]]; then
    info "Existing worktree found at $worktree_path"

    # Fix detached HEAD
    local current_head
    current_head=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
    if [[ "$current_head" == "DETACHED" ]]; then
      warn "Worktree is in detached HEAD state — attempting to fix..."
      if git -C "$worktree_path" checkout "$branch" 2>/dev/null; then
        success "Now tracking branch: $branch"
      elif git -C "$worktree_path" checkout -b "$branch" "origin/$branch" 2>/dev/null; then
        success "Created and tracking branch: $branch"
      else
        warn "Could not fix detached HEAD. Continuing..."
      fi
    fi

    # Get port from registry or assign new
    local port
    port=$(jq -r --arg b "$branch" '.[] | select(.branch == $b and .status == "active") | .port' "$SESSIONS_FILE" | head -1)
    if [[ -z "$port" || "$port" == "null" ]]; then
      port=$(next_port) || exit 1
    fi

    # Setup worktree if .env missing (first time or clean worktree)
    if [[ ! -f "$worktree_path/.env" ]]; then
      setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"
    fi

    # Detect container state and act
    local state
    state=$(detect_session_state "$project")

    if [[ "$state" == "resume" ]]; then
      info "Containers already running"
    else
      # If user wants fresh DB, tear down first
      if [[ "$state" != "first_run" ]] && volume_exists "$project"; then
        if confirm "Database exists from previous run. Drop and re-initialize?"; then
          compose_down "$project" "$worktree_path"
          state="first_run"
        fi
      fi
      compose_up "$project" "$worktree_path" "$port" "$state"
    fi

    # Ensure registry entry
    local in_registry
    in_registry=$(jq -r --arg b "$branch" '.[] | select(.branch == $b and .status == "active") | .branch' "$SESSIONS_FILE" | head -1)
    if [[ -z "$in_registry" ]]; then
      registry_add "$branch" "docker:$project" "$port" "$worktree_path" "${pr_number:-null}"
    fi

    launch_tmux "$tmux_session" "$worktree_path" "$project"
    exit 0
  fi

  # New session — create worktree
  info "Creating session for branch: $branch"
  git -C "$WESCOM_APP_PATH" fetch origin

  if [[ -n "$new_name" ]]; then
    git -C "$WESCOM_APP_PATH" worktree add -b "$branch" "$worktree_path" origin/main
  else
    git -C "$WESCOM_APP_PATH" worktree add "$worktree_path" "$branch" 2>/dev/null || {
      local stale_path
      stale_path=$(git -C "$WESCOM_APP_PATH" worktree list --porcelain 2>/dev/null \
        | awk -v b="$branch" '/^worktree /{p=$2} /^branch refs\/heads\//{if ($2 == "refs/heads/"b && p !~ /wescom-sessions/) print p}')
      if [[ -n "$stale_path" ]]; then
        warn "Branch '$branch' is checked out in a stale worktree at: $stale_path"
        if confirm "Remove stale worktree and continue?"; then
          git -C "$WESCOM_APP_PATH" worktree remove --force "$stale_path" 2>/dev/null
          git -C "$WESCOM_APP_PATH" worktree prune 2>/dev/null
          git -C "$WESCOM_APP_PATH" worktree add "$worktree_path" "$branch" || {
            error "Still could not create worktree."; exit 1
          }
        else
          error "Cannot create session — branch is checked out elsewhere."; exit 1
        fi
      else
        error "Could not create worktree for '$branch'."
        git -C "$WESCOM_APP_PATH" worktree list 2>/dev/null | grep -i "$dir_name" || true
        exit 1
      fi
    }
  fi
  success "Worktree created at $worktree_path"

  local port
  port=$(next_port) || exit 1

  setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"
  compose_up "$project" "$worktree_path" "$port" "first_run"
  registry_add "$branch" "docker:$project" "$port" "$worktree_path" "${pr_number:-null}"

  header "Session Ready"
  echo -e "  ${BOLD}Branch:${NC}    $branch"
  echo -e "  ${BOLD}Port:${NC}      $port → http://localhost:$port"
  echo -e "  ${BOLD}Path:${NC}      $worktree_path"
  echo -e "  ${BOLD}Containers:${NC} docker compose -p $project ps"
  echo ""

  launch_tmux "$tmux_session" "$worktree_path" "$project"
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

  printf "  ${BOLD}%-30s %-6s %-15s %s${NC}\n" "BRANCH" "PORT" "CONTAINERS" "STARTED"
  echo "  $(printf '%.0s─' {1..75})"

  echo "$active" | jq -r '.[] | "\(.branch)\t\(.port // "?")\t\(.started)"' |
  while IFS=$'\t' read -r branch port started; do
    local dir_name
    dir_name=$(slugify "$branch")
    local project
    project=$(compose_project_name "$dir_name")
    local status
    status=$(compose_status_display "$project")
    printf "  %-30s %-6s %-15b %s\n" "${branch:0:28}" "$port" "$status" "$started"
  done
}

# ─── ws end ─────────────────────────────────────────────────────────────────

cmd_end() {
  local branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      -*)       error "Unknown option: $1"; exit 1 ;;
      *)        branch="$1"; shift ;;
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

  local worktree_path
  worktree_path=$(echo "$session" | jq -r '.path')

  local dir_name
  dir_name=$(slugify "$branch")
  local project
  project=$(compose_project_name "$dir_name")

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

  # Stop containers and remove volumes
  info "Stopping containers and removing database..."
  compose_down "$project" "$worktree_path"
  success "Containers stopped, volumes removed"
  echo ""

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

  # Mark ended in registry
  registry_end "$branch"
  success "Session ended: $branch"

  # Kill tmux session
  local tmux_session="ws-$dir_name"
  tmux kill-session -t "$tmux_session" 2>/dev/null && success "Tmux session killed" || true
}

# ─── ws rebuild ─────────────────────────────────────────────────────────────

cmd_rebuild() {
  header "Rebuilding base image"

  # Ensure wescomapp repo exists
  if [[ ! -d "$WESCOM_APP_PATH" ]]; then
    error "WescomApp repo not found at $WESCOM_APP_PATH"
    exit 1
  fi

  info "Fetching latest main..."
  git -C "$WESCOM_APP_PATH" fetch origin

  # Create a temporary build context with dependency files from main
  local build_ctx
  build_ctx=$(mktemp -d)
  trap "rm -rf $build_ctx" EXIT

  info "Copying dependency files from main branch..."
  git -C "$WESCOM_APP_PATH" show origin/main:Gemfile > "$build_ctx/Gemfile"
  git -C "$WESCOM_APP_PATH" show origin/main:Gemfile.lock > "$build_ctx/Gemfile.lock"
  git -C "$WESCOM_APP_PATH" show origin/main:package.json > "$build_ctx/package.json"
  git -C "$WESCOM_APP_PATH" show origin/main:yarn.lock > "$build_ctx/yarn.lock"

  # Copy Dockerfile and entrypoint from ws repo
  cp "$SCRIPT_DIR/Dockerfile" "$build_ctx/"
  cp "$SCRIPT_DIR/docker-entrypoint.sh" "$build_ctx/"

  info "Building image (this may take a few minutes on first run)..."
  docker build -t wescomapp-dev:latest "$build_ctx"

  local size
  size=$(docker image inspect wescomapp-dev:latest --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')
  success "Image built: wescomapp-dev:latest ($size)"
}

# ─── ws exec ────────────────────────────────────────────────────────────────

cmd_exec() {
  if [[ $# -eq 0 ]]; then
    error "Usage: ws exec <command>"
    exit 1
  fi

  local branch
  branch=$(find_session_by_cwd "$(pwd)")
  if [[ -z "$branch" ]]; then
    error "Not in a session directory. cd to a worktree first."
    exit 1
  fi

  local dir_name
  dir_name=$(slugify "$branch")
  local project
  project=$(compose_project_name "$dir_name")
  local worktree_path="$SESSIONS_DIR/$dir_name"

  # Check containers are running
  local status
  status=$(compose_status "$project")
  if [[ "$status" != "running" ]]; then
    error "Containers not running for session '$branch'. Run 'ws attach --branch $branch' first."
    exit 1
  fi

  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec app "$@"
}

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}ws${NC} — WescomApp Session Manager (Docker)

${BOLD}Usage:${NC}
  ws attach --pr <number>            Attach to existing PR
  ws attach --branch <name>          Attach to existing branch
  ws attach --new "description"      Create new branch + session
  ws list                            Show active sessions
  ws end [--branch <name>]           Clean up a session
  ws rebuild                         Rebuild the base Docker image
  ws exec <command>                  Run command in session container

${BOLD}Environment:${NC}
  WESCOM_APP_PATH    Path to WescomApp repo (default: ~/code/WescomApp)

${BOLD}Prerequisites:${NC}
  OrbStack (or Docker), gh, tmux, jq, claude
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  attach)  shift; cmd_attach "$@" ;;
  list)    cmd_list ;;
  end)     shift; cmd_end "$@" ;;
  rebuild) cmd_rebuild ;;
  exec)    shift; cmd_exec "$@" ;;
  -h|--help|help) usage ;;
  *)       usage ;;
esac
