# WS Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the `ws` tool from ~850 lines / 6 commands to ~200 lines / 3 commands with real git branches, proper worktree location, and Claude Code session memory.

**Architecture:** Single `ws` shell script sourcing two unchanged lib files (`colors.sh`, `database.sh`). Worktrees created in `~/code/wescom-sessions/`. Session state tracked in `~/.wescom-sessions.json`. Notion integration and Rails config patching removed entirely.

**Tech Stack:** Bash, git worktrees, PostgreSQL (createdb/dropdb), tmux, gh CLI, jq

**Spec:** `docs/superpowers/specs/2026-03-16-ws-redesign-design.md`

---

## Chunk 1: Cleanup and Scaffolding

### Task 1: Delete removed files

**Files:**
- Delete: `lib/notion.sh`
- Delete: `lib/worktree.sh`

- [ ] **Step 1: Delete notion.sh**

```bash
rm lib/notion.sh
```

- [ ] **Step 2: Delete worktree.sh**

```bash
rm lib/worktree.sh
```

- [ ] **Step 3: Commit**

```bash
git add -u lib/
git commit -m "chore: remove notion.sh and worktree.sh — no longer needed in redesign"
```

---

### Task 2: Write the new `ws` script — shell, sourcing, defaults, helpers

Replace the entire `ws` file with the new lean version. This task covers everything except the three command implementations (attach, list, end) which are separate tasks.

**Files:**
- Rewrite: `ws`

- [ ] **Step 1: Write the script header, sourcing, and defaults**

```bash
#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/database.sh"

# Defaults
: "${WESCOM_APP_PATH:=$HOME/code/WescomApp}"
: "${PG_USER:=$(whoami)}"
: "${PG_BASE_DB:=wescom_app_development}"
SESSIONS_FILE="$HOME/.wescom-sessions.json"
SESSIONS_DIR="$HOME/code/wescom-sessions"

[[ -f "$SESSIONS_FILE" ]] || echo '[]' > "$SESSIONS_FILE"
mkdir -p "$SESSIONS_DIR"
```

- [ ] **Step 2: Write the slugify helper**

```bash
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's|/|-|g; s/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50
}
```

Key difference from old version: slashes become hyphens (for branch names like `feature/search` → `feature-search`).

- [ ] **Step 3: Write registry helpers**

```bash
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
```

- [ ] **Step 4: Write the setup_session helper**

This is the shared logic used by `ws attach` for both new and existing branches — env, session memory, CLAUDE.md, git excludes.

```bash
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
```

- [ ] **Step 5: Write the launch_tmux helper**

```bash
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
```

- [ ] **Step 6: Write the usage function and main dispatch (placeholders for commands)**

```bash
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

case "${1:-}" in
  attach) shift; cmd_attach "$@" ;;
  list)   cmd_list ;;
  end)    shift; cmd_end "$@" ;;
  -h|--help|help) usage ;;
  *)      usage ;;
esac
```

- [ ] **Step 7: Verify script sources and runs usage**

```bash
chmod +x ws
./ws --help
```

Expected: Usage text prints without errors.

- [ ] **Step 8: Commit**

```bash
git add ws
git commit -m "feat: rewrite ws script — shell, helpers, and usage for lean 3-command design"
```

---

## Chunk 2: Command Implementations

### Task 3: Implement `ws attach`

**Files:**
- Modify: `ws` (add `cmd_attach` function)

- [ ] **Step 1: Write arg parsing for cmd_attach**

Insert `cmd_attach` function before the `usage()` function in `ws`:

```bash
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
```

- [ ] **Step 2: Write PR resolution block**

```bash
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
```

- [ ] **Step 3: Write new branch creation block**

```bash
  # Create new branch (fetch first so origin/main is current)
  if [[ -n "$new_name" ]]; then
    branch=$(slugify "$new_name")
    info "Creating new branch: $branch"
    git -C "$WESCOM_APP_PATH" fetch origin
  fi
```

- [ ] **Step 4: Write directory name resolution and collision check**

```bash
  local dir_name
  dir_name=$(slugify "$branch")
  local worktree_path="$SESSIONS_DIR/$dir_name"
  local tmux_session="ws-$dir_name"

  # Check for slug collision with different branch
  local existing_branch
  existing_branch=$(jq -r --arg d "$dir_name" --arg b "$branch" \
    '.[] | select(.status == "active" and (.path | endswith("/"+$d)) and .branch != $b) | .branch' \
    "$SESSIONS_FILE" | head -1)
  if [[ -n "$existing_branch" ]]; then
    error "Directory name '$dir_name' is already used by branch '$existing_branch'."
    exit 1
  fi
```

- [ ] **Step 5: Write resume detection**

```bash
  # Resume existing session
  if [[ -d "$worktree_path" ]]; then
    info "Existing worktree found at $worktree_path"

    # Handle database: check if it exists
    local db_name="wescomapp_dev_${dir_name//-/_}"
    db_name="${db_name:0:63}"
    if db_exists "$db_name"; then
      if confirm "Database '$db_name' exists. Reuse it?"; then
        info "Reusing existing database"
      else
        info "Fresh clone requested"
        db_drop "$db_name"
        db_clone "$db_name" || exit 1
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
  fi
```

- [ ] **Step 6: Write new session creation**

```bash
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
```

- [ ] **Step 7: Verify `ws attach --new "Test session"` works end to end**

```bash
./ws attach --new "Test session"
```

Expected: Creates branch `test-session`, worktree at `~/code/wescom-sessions/test-session/`, clones DB, opens tmux with split panes.

- [ ] **Step 8: Clean up test session and commit**

```bash
# From outside the tmux session:
./ws end --branch test-session
git add ws
git commit -m "feat: implement ws attach — single entry point for new and existing sessions"
```

---

### Task 4: Implement `ws list`

**Files:**
- Modify: `ws` (add `cmd_list` function)

- [ ] **Step 1: Write cmd_list function**

Insert before `usage()`:

```bash
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

  echo "$active" | jq -r '.[] | "\(.branch)\t\(.db)\t\(.port)\t\(.started)"' |
  while IFS=$'\t' read -r branch db port started; do
    printf "  %-30s %-40s %-6s %s\n" "${branch:0:28}" "${db:0:38}" "$port" "$started"
  done

  # Check for orphaned databases
  local session_dbs
  session_dbs=$(db_list_session_dbs)
  if [[ -n "$session_dbs" ]]; then
    local orphaned=""
    while IFS= read -r db; do
      if ! echo "$active" | jq -e --arg db "$db" '.[] | select(.db == $db)' > /dev/null 2>&1; then
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
```

- [ ] **Step 2: Verify `ws list` shows sessions**

```bash
./ws list
```

Expected: Table of active sessions, or "No active sessions." if none exist.

- [ ] **Step 3: Commit**

```bash
git add ws
git commit -m "feat: implement ws list — display active sessions with orphan detection"
```

---

### Task 5: Implement `ws end`

**Files:**
- Modify: `ws` (add `cmd_end` function)

- [ ] **Step 1: Write cmd_end function**

Insert before `usage()`:

```bash
cmd_end() {
  local branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      *)        error "Unknown argument: $1"; exit 1 ;;
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
  db_name=$(echo "$session" | jq -r '.db')
  worktree_path=$(echo "$session" | jq -r '.path')

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
```

- [ ] **Step 2: Verify `ws end` works**

Create a test session, then end it:

```bash
./ws attach --new "End test"
# Detach from tmux (Ctrl-b d)
./ws end --branch end-test
```

Expected: Prompts for push, drop DB, remove worktree. Cleans everything up.

- [ ] **Step 3: Commit**

```bash
git add ws
git commit -m "feat: implement ws end — teardown with interactive prompts"
```

---

## Chunk 3: Install Script and Final Verification

### Task 6: Update install.sh

**Files:**
- Rewrite: `install.sh`

- [ ] **Step 1: Write the updated install.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "ws — WescomApp Session Tool Installer"
echo ""

# Check prerequisites
missing=()
for cmd in git psql createdb dropdb jq gh tmux claude; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing prerequisites:"
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      jq)          echo "  $cmd — brew install jq" ;;
      gh)          echo "  $cmd — brew install gh" ;;
      tmux)        echo "  $cmd — brew install tmux" ;;
      claude)      echo "  $cmd — npm install -g @anthropic-ai/claude-code" ;;
      psql|createdb|dropdb) echo "  $cmd — brew install postgresql" ;;
      *)           echo "  $cmd" ;;
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
echo "  export PG_USER=$(whoami)                          # default"
echo "  export PG_BASE_DB=wescom_app_development          # default"
echo ""
echo "Run: ws attach --new \"My first session\""
```

- [ ] **Step 2: Verify install works**

```bash
chmod +x install.sh
./install.sh
```

Expected: Checks deps, validates gh auth, installs symlink.

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "chore: simplify install.sh — remove Notion, add tmux/gh auth checks"
```

---

### Task 7: End-to-end verification

- [ ] **Step 1: Test `ws attach --new`**

```bash
ws attach --new "Verification test"
```

Verify:
- Worktree exists at `~/code/wescom-sessions/verification-test/`
- Database `wescomapp_dev_verification_test` exists: `psql -lqt | grep verification_test`
- `.env` has DATABASE_URL, PORT, SOLID_QUEUE_IN_PUMA, WEB_CONCURRENCY
- `.session/memory/` directory exists
- `CLAUDE.md` has session context appended
- `.git/info/exclude` contains CLAUDE.md, .session/, .env
- Tmux has split panes (server | claude)
- RubyMine opened the worktree

- [ ] **Step 2: Test `ws list`**

```bash
# Detach from tmux first (Ctrl-b d)
ws list
```

Verify: Shows the verification-test session with correct branch, DB, port.

- [ ] **Step 3: Test `ws attach` resume**

```bash
ws attach --branch verification-test
```

Verify: Reattaches to existing tmux session (no new DB clone).

- [ ] **Step 4: Test `ws end`**

```bash
# Detach from tmux (Ctrl-b d)
ws end --branch verification-test
```

Verify: Prompts for push/drop/remove, cleans everything up. `ws list` shows no active sessions.

- [ ] **Step 5: Final commit**

```bash
git add ws install.sh lib/
git commit -m "chore: ws redesign complete — 3 commands, ~200 lines, real branches"
```
