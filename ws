#!/usr/bin/env bash
set -euo pipefail

# ws — WescomApp Session CLI Tool
# Manages parallel dev sessions with isolated DBs, git worktrees, and Notion syncing.

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
SESSIONS_FILE="$HOME/.wescom-sessions.json"

# Source library files
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/notion.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/worktree.sh"

# Defaults
: "${WESCOM_APP_PATH:=$HOME/code/WescomApp}"
: "${PG_USER:=$(whoami)}"
: "${PG_BASE_DB:=wescom_app_development}"

# Ensure sessions file exists
[[ -f "$SESSIONS_FILE" ]] || echo '[]' > "$SESSIONS_FILE"

# ─── Helpers ────────────────────────────────────────────────────────────────

sessions_add() {
  local branch="$1" db_name="$2" worktree_path="$3" notion_page_id="$4" notion_url="$5" title="$6"
  local now
  now=$(timestamp_readable)

  local tmp
  tmp=$(mktemp)
  jq --arg branch "$branch" \
     --arg db "$db_name" \
     --arg wt "$worktree_path" \
     --arg pid "$notion_page_id" \
     --arg url "$notion_url" \
     --arg title "$title" \
     --arg started "$now" \
     '. + [{
       branch: $branch,
       db_name: $db,
       worktree_path: $wt,
       notion_page_id: $pid,
       notion_url: $url,
       title: $title,
       started: $started,
       status: "active"
     }]' "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

sessions_end() {
  local branch="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg branch "$branch" \
     'map(if .branch == $branch then .status = "ended" else . end)' \
     "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

check_notion_key() {
  if [[ -z "${NOTION_API_KEY:-}" ]]; then
    error "NOTION_API_KEY is not set."
    echo "  Export it in your shell profile or .env:"
    echo "  export NOTION_API_KEY=\"secret_...\""
    exit 1
  fi
}

# ─── ws new ─────────────────────────────────────────────────────────────────

cmd_new() {
  check_notion_key
  header "ws new — Create Session"

  local notion_page_id=""
  local notion_url=""
  local title=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        notion_url="$2"
        notion_page_id=$(notion_extract_page_id "$notion_url")
        shift 2
        ;;
      --name)
        title="$2"
        shift 2
        ;;
      *)
        error "Unknown argument: $1"
        echo "Usage: ws new [--task <url>] [--name \"title\"]"
        exit 1
        ;;
    esac
  done

  # Resolve Notion task
  if [[ -n "$title" && -z "$notion_page_id" ]]; then
    # Create new task in Notion
    info "Creating Notion task: $title"
    local create_response
    create_response=$(notion_create_task "$title")
    notion_page_id=$(echo "$create_response" | jq -r '.id')
    notion_url="https://www.notion.so/${notion_page_id//\-/}"
    success "Notion task created"
  elif [[ -z "$notion_page_id" ]]; then
    # Interactive: pick from open tasks
    info "Fetching open tasks from Notion..."
    local tasks_json
    tasks_json=$(notion_query_open_tasks)
    notion_page_id=$(notion_display_tasks "$tasks_json")
    if [[ -z "$notion_page_id" ]]; then
      exit 1
    fi
    notion_url="https://www.notion.so/${notion_page_id//\-/}"
  fi

  # Fetch task details
  info "Fetching task details..."
  local page_json blocks_json comments_json
  page_json=$(notion_get_page "$notion_page_id")
  blocks_json=$(notion_get_blocks "$notion_page_id")
  comments_json=$(notion_get_comments "$notion_page_id")

  title=$(notion_extract_title "$page_json")
  local description
  description=$(notion_extract_description "$page_json")
  local page_content
  page_content=$(notion_blocks_to_markdown "$blocks_json")
  local comments
  comments=$(notion_comments_to_markdown "$comments_json")

  success "Task: $title"

  # Generate names
  local slug ts branch db_name
  slug=$(slugify "$title")
  ts=$(timestamp)
  branch="${slug}-${ts}"
  db_name="wescomapp_dev_${slug//-/_}_${ts//-/_}"
  # Truncate DB name at 63 chars for Postgres
  db_name="${db_name:0:63}"

  info "Branch: $branch"
  info "Database: $db_name"

  # Clone database
  db_clone "$db_name" || exit 1

  # Create worktree
  local worktree_path
  worktree_path=$(worktree_create "$branch") || exit 1

  # Setup .env
  worktree_setup_env "$worktree_path" "$db_name"

  # Write SESSION_NOTES.md
  write_session_notes "$worktree_path" "$title" "$branch" "$db_name" "$notion_url" \
    "$description" "$page_content" "$comments"

  # Write CLAUDE.md
  write_claude_md "$worktree_path" "$branch" "$db_name" "$notion_url"

  # Update Notion status to In Progress
  info "Updating Notion status → In Progress"
  notion_update_status "$notion_page_id" "In Progress" > /dev/null
  success "Notion task marked as In Progress"

  # Log session
  sessions_add "$branch" "$db_name" "$worktree_path" "$notion_page_id" "$notion_url" "$title"

  # Summary
  header "Session Ready"
  echo -e "  ${BOLD}Branch:${NC}    $branch"
  echo -e "  ${BOLD}Database:${NC}  $db_name"
  echo -e "  ${BOLD}Worktree:${NC}  $worktree_path"
  echo -e "  ${BOLD}Notion:${NC}    $notion_url"
  echo ""
  info "Launching Claude Code in worktree..."
  echo ""

  cd "$worktree_path" && exec claude
}

# ─── ws attach ──────────────────────────────────────────────────────────────

cmd_attach() {
  header "ws attach — Attach to Existing Branch"

  local branch=""
  local pr_number=""
  local notion_url=""
  local notion_page_id=""
  local no_claude=false

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch="$2"
        shift 2
        ;;
      --pr)
        pr_number="$2"
        shift 2
        ;;
      --task)
        notion_url="$2"
        shift 2
        ;;
      --no-claude)
        no_claude=true
        shift
        ;;
      *)
        error "Unknown argument: $1"
        echo "Usage: ws attach (--branch <name> | --pr <number>) [--task <url>] [--no-claude]"
        exit 1
        ;;
    esac
  done

  # ── Validate: exactly one of --branch or --pr ──
  if [[ -n "$branch" && -n "$pr_number" ]]; then
    error "Use either --branch or --pr, not both."
    exit 1
  fi
  if [[ -z "$branch" && -z "$pr_number" ]]; then
    error "Either --branch or --pr is required."
    echo "Usage: ws attach (--branch <name> | --pr <number>) [--task <url>] [--no-claude]"
    exit 1
  fi

  # ── Validate Notion key if --task provided ──
  if [[ -n "$notion_url" ]]; then
    check_notion_key
    notion_page_id=$(notion_extract_page_id "$notion_url")
  fi

  # ── Resolve branch from PR ──
  if [[ -n "$pr_number" ]]; then
    if ! command -v gh &>/dev/null; then
      error "GitHub CLI (gh) is not installed."
      echo "  Install: brew install gh"
      exit 1
    fi

    info "Resolving branch from PR #${pr_number}..."
    local pr_json
    pr_json=$(gh pr view "$pr_number" --json state,headRefName 2>/dev/null) || {
      error "PR #${pr_number} not found."
      exit 1
    }

    local pr_state
    pr_state=$(echo "$pr_json" | jq -r '.state')
    if [[ "$pr_state" != "OPEN" ]]; then
      error "PR #${pr_number} is ${pr_state}, not open. Branch may no longer exist."
      exit 1
    fi

    branch=$(echo "$pr_json" | jq -r '.headRefName')
    success "PR #${pr_number} → branch: $branch"
  fi

  # ── Validate branch exists ──
  info "Checking branch: $branch"
  if ! git -C "$WESCOM_APP_PATH" rev-parse --verify "$branch" &>/dev/null; then
    info "Not found locally, fetching from origin..."
    git -C "$WESCOM_APP_PATH" fetch origin "$branch" 2>/dev/null || {
      error "Branch '$branch' not found locally or on origin."
      exit 1
    }
    # Create local tracking branch if it doesn't exist
    if ! git -C "$WESCOM_APP_PATH" rev-parse --verify "$branch" &>/dev/null; then
      git -C "$WESCOM_APP_PATH" branch "$branch" "origin/$branch" 2>/dev/null || {
        error "Failed to create local tracking branch for '$branch'."
        exit 1
      }
    fi
  fi
  success "Branch verified: $branch"

  # ── Check for existing worktree — resume if found ──
  if git -C "$WESCOM_APP_PATH" worktree list --porcelain | grep -q "branch refs/heads/$branch$"; then
    local existing_wt
    existing_wt=$(git -C "$WESCOM_APP_PATH" worktree list --porcelain | grep -B2 "branch refs/heads/$branch$" | grep "^worktree " | sed 's/^worktree //')
    warn "Existing worktree found at: $existing_wt"
    info "Resuming session..."

    local worktree_path="$existing_wt"
    local tmux_session
    tmux_session="ws-$(slugify "$branch")"

    # If tmux session already exists, just reattach
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      info "Reattaching to tmux session: $tmux_session"
      exec tmux attach -t "$tmux_session"
    fi

    # Ensure .env and puma.rb are set up (worktree may predate ws attach)
    local slug db_name
    slug=$(slugify "$branch")
    db_name="wescomapp_dev_${slug//-/_}"
    db_name="${db_name:0:63}"
    if [[ ! -f "$worktree_path/.env" ]]; then
      worktree_setup_env "$worktree_path" "$db_name"
    fi

    # Register session if not already tracked
    local active_session
    active_session=$(jq --arg branch "$branch" '.[] | select(.branch == $branch and .status == "active")' "$SESSIONS_FILE" 2>/dev/null)
    if [[ -z "$active_session" ]]; then
      sessions_add "$branch" "$db_name" "$worktree_path" "" "N/A" "$branch"
      success "Session registered"
    fi

    # Otherwise start a fresh tmux session for the existing worktree
    info "Starting tmux session: $tmux_session"
    echo -e "  ${DIM}Switch windows: Ctrl-b n / Ctrl-b p${NC}"
    echo -e "  ${DIM}Detach: Ctrl-b d | Reattach: tmux attach -t $tmux_session${NC}"
    echo ""

    # Open RubyMine
    open -a "RubyMine" "$worktree_path" 2>/dev/null &

    tmux new-session -d -s "$tmux_session" -c "$worktree_path" -n "server"
    tmux send-keys -t "$tmux_session:server" "set -a; [ -f .env ] && source .env; set +a; for p in 3000 3001 3002 3003 3004; do lsof -iTCP:\$p -sTCP:LISTEN -t >/dev/null 2>&1 || { export PORT=\$p; break; }; done; bin/dev" Enter

    if [[ "$no_claude" == true ]]; then
      tmux new-window -t "$tmux_session" -n "code" -c "$worktree_path"
    else
      tmux new-window -t "$tmux_session" -n "code" -c "$worktree_path"
      tmux send-keys -t "$tmux_session:code" "claude" Enter
    fi

    tmux select-window -t "$tmux_session:code"
    exec tmux attach -t "$tmux_session"
  fi

  # ── Generate database name ──
  local slug db_name
  slug=$(slugify "$branch")
  db_name="wescomapp_dev_${slug//-/_}"
  db_name="${db_name:0:63}"

  info "Branch: $branch"
  info "Database: $db_name"

  # ── Check DB collision ──
  if db_exists "$db_name"; then
    error "Database '$db_name' already exists. Clean up with 'ws end' or drop manually."
    exit 1
  fi

  # ── Clone database ──
  db_clone "$db_name" || exit 1

  # ── Create worktree ──
  local worktree_path
  worktree_path=$(worktree_attach "$branch") || exit 1

  # ── Setup .env ──
  worktree_setup_env "$worktree_path" "$db_name"

  # ── Resolve title and Notion content ──
  local title description page_content comments
  title="$branch"
  description=""
  page_content=""
  comments=""

  if [[ -n "$notion_page_id" ]]; then
    info "Fetching task details from Notion..."
    local page_json blocks_json comments_json
    page_json=$(notion_get_page "$notion_page_id")
    blocks_json=$(notion_get_blocks "$notion_page_id")
    comments_json=$(notion_get_comments "$notion_page_id")

    title=$(notion_extract_title "$page_json")
    description=$(notion_extract_description "$page_json")
    page_content=$(notion_blocks_to_markdown "$blocks_json")
    comments=$(notion_comments_to_markdown "$comments_json")

    success "Task: $title"
  else
    notion_url="N/A"
  fi

  # ── Write SESSION_NOTES.md ──
  write_session_notes "$worktree_path" "$title" "$branch" "$db_name" "$notion_url" \
    "$description" "$page_content" "$comments"

  # ── Write CLAUDE.md ──
  write_claude_md "$worktree_path" "$branch" "$db_name" "$notion_url"

  # ── Update Notion ──
  if [[ -n "$notion_page_id" ]]; then
    info "Updating Notion status → In Progress"
    notion_update_status "$notion_page_id" "In Progress" > /dev/null
    success "Notion task marked as In Progress"
  fi

  # ── Register session ──
  sessions_add "$branch" "$db_name" "$worktree_path" "${notion_page_id:-}" "$notion_url" "$title"

  # ── Summary ──
  header "Session Ready"
  echo -e "  ${BOLD}Branch:${NC}    $branch"
  echo -e "  ${BOLD}Database:${NC}  $db_name"
  echo -e "  ${BOLD}Worktree:${NC}  $worktree_path"
  echo -e "  ${BOLD}Notion:${NC}    $notion_url"
  echo ""

  # ── Launch tmux session ──
  local tmux_session
  tmux_session="ws-$(slugify "$branch")"

  info "Starting tmux session: $tmux_session"
  echo -e "  ${DIM}Switch windows: Ctrl-b n / Ctrl-b p${NC}"
  echo -e "  ${DIM}Detach: Ctrl-b d | Reattach: tmux attach -t $tmux_session${NC}"
  echo ""

  # Open RubyMine
  open -a "RubyMine" "$worktree_path" 2>/dev/null &

  # Create tmux session with server window
  tmux new-session -d -s "$tmux_session" -c "$worktree_path" -n "server"
  tmux send-keys -t "$tmux_session:server" "set -a; [ -f .env ] && source .env; set +a; for p in 3000 3001 3002 3003 3004; do lsof -iTCP:\$p -sTCP:LISTEN -t >/dev/null 2>&1 || { export PORT=\$p; break; }; done; bin/dev" Enter

  # Create code window
  if [[ "$no_claude" == true ]]; then
    tmux new-window -t "$tmux_session" -n "code" -c "$worktree_path"
  else
    tmux new-window -t "$tmux_session" -n "code" -c "$worktree_path"
    tmux send-keys -t "$tmux_session:code" "claude" Enter
  fi

  # Attach to the code window
  tmux select-window -t "$tmux_session:code"
  exec tmux attach -t "$tmux_session"
}

# ─── ws list ────────────────────────────────────────────────────────────────

cmd_list() {
  header "Active Sessions"

  local active_count
  active_count=$(jq '[.[] | select(.status == "active")] | length' "$SESSIONS_FILE")

  if [[ "$active_count" == "0" ]]; then
    dim "  No active sessions."
  else
    printf "  ${BOLD}%-40s %-35s %-40s %s${NC}\n" "BRANCH" "TASK" "DATABASE" "STARTED"
    echo "  $(printf '%.0s─' {1..130})"

    jq -r '.[] | select(.status == "active") |
      "  \(.branch)\t\(.title)\t\(.db_name)\t\(.started)"' "$SESSIONS_FILE" |
    while IFS=$'\t' read -r branch title db started; do
      # Truncate long values
      local b_trunc="${branch:0:38}"
      local t_trunc="${title:0:33}"
      local d_trunc="${db:0:38}"
      printf "  %-40s %-35s %-40s %s\n" "$b_trunc" "$t_trunc" "$d_trunc" "$started"
    done
  fi

  # Check for orphaned databases
  echo ""
  local session_dbs
  session_dbs=$(db_list_session_dbs)
  if [[ -n "$session_dbs" ]]; then
    local orphaned=""
    while IFS= read -r db; do
      if ! jq -e --arg db "$db" '.[] | select(.status == "active" and .db_name == $db)' "$SESSIONS_FILE" > /dev/null 2>&1; then
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

# ─── ws sync ────────────────────────────────────────────────────────────────

cmd_sync() {
  check_notion_key
  header "ws sync — Refresh from Notion"

  local branch=""
  local worktree_path=""
  local notion_page_id=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch="$2"
        shift 2
        ;;
      *)
        error "Unknown argument: $1"
        echo "Usage: ws sync [--branch <name>]"
        exit 1
        ;;
    esac
  done

  # Detect session
  if [[ -z "$branch" ]]; then
    branch=$(detect_session_from_cwd "$(pwd)")
    if [[ -z "$branch" ]]; then
      # Try to find SESSION_NOTES.md in current dir
      if [[ -f "$(pwd)/SESSION_NOTES.md" ]]; then
        worktree_path="$(pwd)"
      else
        error "Not in a session directory. Use --branch <name> or cd into a session worktree."
        exit 1
      fi
    fi
  fi

  # Get session info
  if [[ -z "$worktree_path" ]]; then
    local session_info
    session_info=$(get_session_by_branch "$branch")
    if [[ -z "$session_info" ]]; then
      error "No session found for branch: $branch"
      exit 1
    fi
    worktree_path=$(echo "$session_info" | jq -r '.worktree_path')
    notion_page_id=$(echo "$session_info" | jq -r '.notion_page_id')
  fi

  # Extract Notion URL from SESSION_NOTES.md if we don't have page ID
  if [[ -z "$notion_page_id" ]]; then
    local notion_url
    notion_url=$(grep -oP '(?<=\*\*Notion:\*\* ).*' "$worktree_path/SESSION_NOTES.md" 2>/dev/null || true)
    if [[ -z "$notion_url" ]]; then
      error "Cannot find Notion URL in SESSION_NOTES.md"
      exit 1
    fi
    notion_page_id=$(notion_extract_page_id "$notion_url")
  fi

  info "Fetching from Notion..."
  local page_json blocks_json comments_json
  page_json=$(notion_get_page "$notion_page_id")
  blocks_json=$(notion_get_blocks "$notion_page_id")
  comments_json=$(notion_get_comments "$notion_page_id")

  local title description page_content comments
  title=$(notion_extract_title "$page_json")
  description=$(notion_extract_description "$page_json")
  page_content=$(notion_blocks_to_markdown "$blocks_json")
  comments=$(notion_comments_to_markdown "$comments_json")

  local comment_count
  comment_count=$(echo "$comments_json" | jq '.results | length' 2>/dev/null || echo "0")
  local block_count
  block_count=$(echo "$blocks_json" | jq '.results | length' 2>/dev/null || echo "0")

  # Read existing SESSION_NOTES.md and preserve header + sync history
  local notes_file="$worktree_path/SESSION_NOTES.md"
  local header_section sync_section
  header_section=$(sed '/^---$/,$ d' "$notes_file")
  sync_section=$(sed -n '/^## Sync History/,$ p' "$notes_file")

  local now
  now=$(timestamp_readable)

  # Rewrite SESSION_NOTES.md
  cat > "$notes_file" <<EOF
${header_section}
---

## Task Description

${description}

---

## Notion Page Content

${page_content}

---

## Comments

${comments}

---

${sync_section}
- ${now} — Synced from Notion (${comment_count} comments, ${block_count} blocks)
EOF

  success "SESSION_NOTES.md updated"
  info "$comment_count comments, $block_count content blocks synced"
}

# ─── ws end ─────────────────────────────────────────────────────────────────

cmd_end() {
  header "ws end — Close Session"

  local branch=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch="$2"
        shift 2
        ;;
      *)
        error "Unknown argument: $1"
        echo "Usage: ws end [--branch <name>]"
        exit 1
        ;;
    esac
  done

  # Detect session
  if [[ -z "$branch" ]]; then
    branch=$(detect_session_from_cwd "$(pwd)")
    if [[ -z "$branch" ]]; then
      # Fallback: detect branch from git
      branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [[ -z "$branch" || "$branch" == "main" ]]; then
        error "Not in a session directory. Use --branch <name> or cd into a session worktree."
        exit 1
      fi
    fi
  fi

  local session_info
  session_info=$(get_session_by_branch "$branch")
  if [[ -z "$session_info" ]]; then
    # No session registered — build minimal info from current state
    warn "No registered session for branch '$branch'. Cleaning up from current state."
    local slug db_name worktree_path
    slug=$(slugify "$branch")
    db_name="wescomapp_dev_${slug//-/_}"
    db_name="${db_name:0:63}"
    worktree_path="$(pwd)"
    session_info=$(jq -n --arg branch "$branch" --arg db "$db_name" --arg wt "$worktree_path" \
      '{branch: $branch, db_name: $db, worktree_path: $wt, notion_page_id: "", title: $branch}')
  fi

  local db_name worktree_path notion_page_id title
  db_name=$(echo "$session_info" | jq -r '.db_name')
  worktree_path=$(echo "$session_info" | jq -r '.worktree_path')
  notion_page_id=$(echo "$session_info" | jq -r '.notion_page_id')
  title=$(echo "$session_info" | jq -r '.title')

  info "Ending session: ${BOLD}$title${NC}"
  echo ""

  # Show git status
  if [[ -d "$worktree_path" ]]; then
    local commits_ahead
    commits_ahead=$(git -C "$worktree_path" rev-list --count main..HEAD 2>/dev/null || echo "0")
    local uncommitted
    uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    info "Commits ahead of main: $commits_ahead"
    info "Uncommitted files: $uncommitted"
    echo ""
  fi

  # Notion status update
  if [[ -n "${NOTION_API_KEY:-}" && -n "$notion_page_id" ]]; then
    local status_choice
    status_choice=$(prompt_choice "Update Notion status?" "In Review" "Done" "Skip")
    case "$status_choice" in
      1) notion_update_status "$notion_page_id" "In Review" > /dev/null; success "Notion → In Review" ;;
      2) notion_update_status "$notion_page_id" "Done" > /dev/null; success "Notion → Done" ;;
      *) dim "  Skipped Notion update" ;;
    esac
    echo ""
  fi

  # Push branch
  if confirm "Push branch to origin?"; then
    git -C "$worktree_path" push -u origin "$branch" 2>/dev/null && success "Branch pushed" || warn "Push failed (may already be pushed)"
    echo ""
  fi

  # Drop database
  if confirm "Drop isolated database ($db_name)?"; then
    db_drop "$db_name"
    echo ""
  fi

  # Remove worktree
  if confirm "Remove worktree ($worktree_path)?"; then
    # cd out of worktree first if we're in it
    if [[ "$(pwd)" == "$worktree_path"* ]]; then
      cd "$WESCOM_APP_PATH"
    fi
    worktree_remove "$branch"
    echo ""
  fi

  # Kill tmux session if running
  local tmux_session
  tmux_session="ws-$(slugify "$branch")"
  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux kill-session -t "$tmux_session" 2>/dev/null
    success "Tmux session killed: $tmux_session"
    echo ""
  fi

  # Mark session as ended
  sessions_end "$branch"
  success "Session ended: $branch"
}

# ─── ws pr ──────────────────────────────────────────────────────────────────

cmd_pr() {
  header "ws pr — Create Pull Request"

  # Check gh CLI
  if ! command -v gh &>/dev/null; then
    error "GitHub CLI (gh) is not installed."
    echo "  Install: brew install gh"
    exit 1
  fi

  # Detect session
  local branch
  branch=$(detect_session_from_cwd "$(pwd)")
  local worktree_path="$(pwd)"

  if [[ -z "$branch" ]]; then
    # Try to get branch from git
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [[ -z "$branch" || "$branch" == "main" ]]; then
      error "Not in a session worktree or feature branch."
      exit 1
    fi
  fi

  # Push if needed
  local remote_branch
  remote_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
  if [[ -z "$remote_branch" ]]; then
    info "Pushing branch to origin..."
    git push -u origin "$branch"
    success "Branch pushed"
  fi

  # Create PR
  info "Creating pull request..."
  gh pr create --fill

  local pr_url
  pr_url=$(gh pr view --json url -q '.url' 2>/dev/null || true)

  if [[ -n "$pr_url" ]]; then
    success "PR created: $pr_url"

    # Optionally update Notion
    local session_info
    session_info=$(get_session_by_branch "$branch")
    if [[ -n "$session_info" && -n "${NOTION_API_KEY:-}" ]]; then
      local notion_page_id
      notion_page_id=$(echo "$session_info" | jq -r '.notion_page_id')
      if [[ -n "$notion_page_id" && "$notion_page_id" != "null" ]]; then
        if confirm "Add PR URL to Notion task?"; then
          notion_patch "$NOTION_API_BASE/pages/$notion_page_id" \
            "{\"properties\": {\"url\": {\"url\": \"$pr_url\"}}}" > /dev/null
          success "PR URL added to Notion"
        fi
      fi
    fi
  fi
}

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}ws${NC} — WescomApp Session Manager

${BOLD}Usage:${NC}
  ws new    [--task <url>] [--name "title"]                   Create a new dev session
  ws attach (--branch <name> | --pr <num>) [--task <url>]     Attach to existing branch
            [--no-claude]
  ws list                                                     Show active sessions
  ws sync   [--branch <name>]                                 Refresh SESSION_NOTES.md from Notion
  ws end    [--branch <name>]                                 Clean up a session
  ws pr                                                       Push and open a GitHub PR

${BOLD}Environment:${NC}
  WESCOM_APP_PATH    Path to WescomApp repo (default: ~/code/WescomApp)
  NOTION_API_KEY     Notion internal integration token (required for new/sync)
  PG_USER            PostgreSQL user (default: \$(whoami))
  PG_BASE_DB         Source database to clone (default: wescomapp_development)

${BOLD}Examples:${NC}
  ws new                                    Interactive task picker
  ws new --task https://notion.so/...       Start from existing task
  ws new --name "Fix invoice totals"        Create new task and start
  ws attach --pr 172                        Attach to PR #172
  ws attach --branch feature/foo            Attach to existing branch
  ws attach --pr 172 --no-claude            Attach without launching Claude
  ws sync                                   Refresh notes in current session
  ws end                                    End current session
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "${1:-}" in
  new)    shift; cmd_new "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  list)   cmd_list ;;
  sync)   shift; cmd_sync "$@" ;;
  end)    shift; cmd_end "$@" ;;
  pr)     cmd_pr ;;
  -h|--help|help) usage ;;
  *)      usage ;;
esac
