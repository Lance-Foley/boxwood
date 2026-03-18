# Containerized Development Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace native PostgreSQL + Rails config patching with fully isolated Docker Compose stacks per session, using OrbStack as the Docker runtime.

**Architecture:** A golden base image (Ruby 3.4.4, gems, Node 20, yarn, foreman) is built manually via `ws rebuild`. Per-session, `ws attach` generates a docker-compose.yml from a template, spins up Postgres + Rails (via foreman for Puma + Tailwind watcher) + SolidQueue worker containers, with the host worktree mounted for live editing.

**Tech Stack:** Bash, Docker/OrbStack, Docker Compose, PostgreSQL 16, Ruby 3.4.4, Rails 8.0.2, Node 20, Yarn 1.22.x, Foreman, jq

**Spec:** `docs/superpowers/specs/2026-03-18-containerized-sessions-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Dockerfile` | Golden base image: Ruby 3.4.4, system deps, gems, node modules, foreman |
| Create | `docker-entrypoint.sh` | Container startup: dependency drift check, DB init on first run |
| Create | `docker-compose.template.yml` | Template: db + app + worker services, variable placeholders |
| Create | `lib/docker.sh` | Docker helper functions: image check, compose generation, container status, first-run detection |
| Rewrite | `ws` | All commands rewritten for Docker lifecycle (attach, list, end, rebuild, exec) |
| Modify | `install.sh` | Update prerequisites: docker instead of psql/createdb/dropdb |
| Remove | `lib/database.sh` | Replaced entirely by Docker container lifecycle |

---

### Task 1: Create Dockerfile

**Files:**
- Create: `Dockerfile`

**Context:** The golden base image provides Ruby 3.4.4, Node 20, Yarn, system deps, pre-installed gems and node modules, foreman (for Procfile.dev which runs Puma + Tailwind CSS watcher), and PostgreSQL client tools. Application code is NOT included — it's mounted at runtime.

- [ ] **Step 1: Create the Dockerfile**

```dockerfile
FROM ruby:3.4.4-slim-bookworm

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    git \
    curl \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 via nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Yarn
RUN npm install -g yarn

WORKDIR /app

# Pre-install gems from main branch (baked into image for speed)
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

# Pre-install node modules from main branch
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Install foreman (used by bin/dev to run Procfile.dev: web + css)
RUN gem install foreman

# Entrypoint handles dependency drift and DB init
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]

# Default: run the dev server via foreman (Puma + Tailwind watcher)
CMD ["foreman", "start", "-f", "Procfile.dev"]
```

- [ ] **Step 2: Verify Dockerfile syntax**

Run: `cd /Users/lancefoley/code/wescom-session && docker build --check -f Dockerfile .` (or just visually inspect — no build yet since we need the entrypoint first)

Expected: File exists at `Dockerfile`, no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile for golden base image (Ruby 3.4.4, Node 20)"
```

---

### Task 2: Create docker-entrypoint.sh

**Files:**
- Create: `docker-entrypoint.sh`

**Context:** Runs inside the container on every start. Handles two concerns: (1) dependency drift — if the branch added gems/packages not in the base image, install them; (2) DB initialization — on first run only (when `DB_INIT=true`), restore `latest.dump`, run migrations, reset dev passwords.

- [ ] **Step 1: Create the entrypoint script**

```bash
#!/bin/bash
set -e

echo "==> Checking dependencies..."

# Handle dependency drift: branches may add gems not in the base image.
# bundle_cache volume persists installs so this only runs once per new gem.
bundle check > /dev/null 2>&1 || {
  echo "==> Installing missing gems..."
  bundle install --jobs 4
}

# Handle node dependency drift (yarn install is a fast no-op when deps match)
yarn install --frozen-lockfile --check-files > /dev/null 2>&1 || yarn install

# Database initialization (only on first run, controlled by ws attach)
if [ "$DB_INIT" = "true" ]; then
  echo "==> Waiting for PostgreSQL..."
  until pg_isready -h db -U postgres -q; do
    sleep 1
  done

  echo "==> Restoring latest.dump..."
  # pg_restore returns non-zero on warnings (e.g. extension already exists) — this is OK
  pg_restore --no-owner --no-acl -h db -U postgres -d wescomapp /dumps/latest.dump || true

  echo "==> Running migrations..."
  bundle exec rails db:migrate

  echo "==> Resetting dev passwords..."
  bundle exec rake update_encrypted_passwords

  echo "==> Database ready."
fi

# Hand off to the CMD (foreman, rails, bash, etc.)
exec "$@"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x /Users/lancefoley/code/wescom-session/docker-entrypoint.sh`

- [ ] **Step 3: Commit**

```bash
git add docker-entrypoint.sh
git commit -m "feat: add docker-entrypoint.sh for dependency drift and DB init"
```

---

### Task 3: Create docker-compose.template.yml

**Files:**
- Create: `docker-compose.template.yml`

**Context:** This is a template file. `ws attach` reads it and substitutes variables (`__HOST_PORT__`, `__WORKTREE_PATH__`, `__WESCOM_APP_PATH__`) to generate a per-session `docker-compose.yml` in the worktree directory. Uses `sed` placeholder substitution (not shell envsubst) so the template is self-contained.

**Note on Procfile.dev:** WescomApp's `Procfile.dev` runs two processes via foreman: `web` (Rails/Puma server) and `css` (Tailwind CSS watcher). The `app` container runs `foreman start -f Procfile.dev` to get both. The `worker` container overrides this to run SolidQueue only.

- [ ] **Step 1: Create the compose template**

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: wescomapp
      POSTGRES_HOST_AUTH_METHOD: trust
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      timeout: 5s
      retries: 10

  app:
    image: wescomapp-dev:latest
    environment:
      DATABASE_URL: postgres://postgres@db/wescomapp
      SOLID_QUEUE_IN_PUMA: "false"
      PORT: "3000"
      DB_INIT: "__DB_INIT__"
    ports:
      - "__HOST_PORT__:3000"
    volumes:
      - __WORKTREE_PATH__:/app
      - __WESCOM_APP_PATH__/latest.dump:/dumps/latest.dump:ro
      - bundle_cache:/usr/local/bundle
      - node_cache:/app/node_modules
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - __WORKTREE_PATH__/.env

  worker:
    image: wescomapp-dev:latest
    command: bundle exec rails solid_queue:start
    environment:
      DATABASE_URL: postgres://postgres@db/wescomapp
      SOLID_QUEUE_IN_PUMA: "false"
    volumes:
      - __WORKTREE_PATH__:/app
      - bundle_cache:/usr/local/bundle
    depends_on:
      app:
        condition: service_started
      db:
        condition: service_healthy
    env_file:
      - __WORKTREE_PATH__/.env
    restart: on-failure:3

volumes:
  pgdata:
  bundle_cache:
  node_cache:
```

Note: `node_cache` volume prevents mounted `node_modules/` from the host (which may have macOS-native binaries) from conflicting with the Linux container's node modules. The volume overlays the host directory inside the container.

- [ ] **Step 2: Commit**

```bash
git add docker-compose.template.yml
git commit -m "feat: add docker-compose template for per-session stacks"
```

---

### Task 4: Create lib/docker.sh

**Files:**
- Create: `lib/docker.sh`

**Context:** Docker helper functions that replace `lib/database.sh`. These wrap Docker/Compose CLI commands for image checking, compose file generation, container status queries, and first-run detection. Sourced by `ws` at startup.

- [ ] **Step 1: Create lib/docker.sh**

```bash
#!/usr/bin/env bash
# Docker Compose session helpers

# Check if the golden base image exists
image_exists() {
  docker image inspect wescomapp-dev:latest > /dev/null 2>&1
}

# Generate a docker-compose.yml from the template for a specific session
generate_compose() {
  local worktree_path="$1" host_port="$2" db_init="$3"
  local template="$SCRIPT_DIR/docker-compose.template.yml"
  local output="$worktree_path/docker-compose.yml"

  sed \
    -e "s|__WORKTREE_PATH__|${worktree_path}|g" \
    -e "s|__WESCOM_APP_PATH__|${WESCOM_APP_PATH}|g" \
    -e "s|__HOST_PORT__|${host_port}|g" \
    -e "s|__DB_INIT__|${db_init}|g" \
    "$template" > "$output"
}

# Get the compose project name for a branch (slugified, prefixed with ws-)
compose_project_name() {
  local branch_slug="$1"
  echo "ws-${branch_slug}"
}

# Check if a compose project has running containers
# Returns: "running", "stopped", or "none"
compose_status() {
  local project="$1"
  local running
  running=$(docker compose -p "$project" ps --status running --format json 2>/dev/null | head -1)

  if [[ -n "$running" && "$running" != "[]" ]]; then
    echo "running"
    return 0
  fi

  # Check if project exists at all (stopped containers or volumes)
  local any
  any=$(docker compose -p "$project" ps --format json 2>/dev/null | head -1)
  if [[ -n "$any" && "$any" != "[]" ]]; then
    echo "stopped"
    return 0
  fi

  echo "none"
}

# Check if the pgdata volume exists for a project
volume_exists() {
  local project="$1"
  docker volume inspect "${project}_pgdata" > /dev/null 2>&1
}

# Detect session state: "first_run", "resume", "restart"
# - first_run: no containers, no volume → DB_INIT=true needed
# - resume: containers running → just attach tmux
# - restart: containers stopped but volume exists → start without DB_INIT
detect_session_state() {
  local project="$1"
  local status
  status=$(compose_status "$project")

  case "$status" in
    running)
      echo "resume"
      ;;
    stopped)
      echo "restart"
      ;;
    none)
      if volume_exists "$project"; then
        echo "restart"
      else
        echo "first_run"
      fi
      ;;
  esac
}

# Start a compose stack (handles first_run vs restart)
compose_up() {
  local project="$1" worktree_path="$2" host_port="$3" state="$4"

  local db_init="false"
  if [[ "$state" == "first_run" ]]; then
    db_init="true"
  fi

  generate_compose "$worktree_path" "$host_port" "$db_init"

  info "Starting containers (${state})..."
  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" up -d

  if [[ "$state" == "first_run" ]]; then
    info "Waiting for database initialization (restore + migrate + password reset)..."
    # Follow app logs until "Database ready." appears, with 5-minute timeout
    # If the container exits or hangs, timeout prevents blocking forever
    timeout 300 docker compose -p "$project" logs -f app 2>&1 | while IFS= read -r line; do
      echo "  $line"
      if [[ "$line" == *"Database ready."* ]]; then
        break
      fi
    done
    if [[ $? -eq 124 ]]; then
      error "Database initialization timed out after 5 minutes. Check: docker compose -p $project logs app"
    fi

    # After DB init, recreate app without DB_INIT so restarts don't re-init
    generate_compose "$worktree_path" "$host_port" "false"
    docker compose -p "$project" -f "$worktree_path/docker-compose.yml" up -d app
  fi

  success "Containers running on port $host_port"
}

# Stop and remove a compose stack (including volumes)
compose_down() {
  local project="$1" worktree_path="$2"
  local compose_file="$worktree_path/docker-compose.yml"

  if [[ -f "$compose_file" ]]; then
    docker compose -p "$project" -f "$compose_file" down -v 2>/dev/null
  else
    # No compose file — try to stop by project name anyway
    docker compose -p "$project" down -v 2>/dev/null || true
  fi
}

# Get container status summary for ws list display
compose_status_display() {
  local project="$1"
  local status
  status=$(compose_status "$project")

  case "$status" in
    running) echo -e "\033[0;32mrunning\033[0m" ;;
    stopped) echo -e "\033[1;33mstopped\033[0m" ;;
    none)    echo -e "\033[2mno containers\033[0m" ;;
  esac
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/docker.sh
git commit -m "feat: add lib/docker.sh — Docker Compose session helpers"
```

---

### Task 5: Rewrite ws — core structure, helpers, and registry

**Files:**
- Modify: `ws` (lines 1–110 approximately: header, sourcing, defaults, helpers)

**Context:** Update the script header to source `lib/docker.sh` instead of `lib/database.sh`. Remove PostgreSQL-specific defaults (`PG_USER`, `PG_BASE_DB`). Remove functions that are no longer needed: `db_prepare`, `sync_env_var`, `patch_database_yml`, `setup_session` (the big monolithic one). Replace `setup_session` with a simpler `setup_worktree` that only handles .env copy, session memory, CLAUDE.md, and git excludes — no more Rails config patching. Update `next_port` range to 3001–3010.

- [ ] **Step 1: Update script header and sourcing**

Replace lines 15–22 (source database.sh line and defaults). **Keep line 14** (`source "$SCRIPT_DIR/lib/colors.sh"`) — it provides `info`, `success`, `warn`, `error`, `header`, `dim`, `confirm` used everywhere.

```bash
source "$SCRIPT_DIR/lib/docker.sh"

# Defaults
: "${WESCOM_APP_PATH:=$HOME/code/WescomApp}"
: "${SESSIONS_FILE:=$HOME/.wescom-sessions.json}"
: "${SESSIONS_DIR:=$HOME/code/wescom-sessions}"

# Ensure sessions file exists and sessions dir exists
[[ -f "$SESSIONS_FILE" ]] || echo '[]' > "$SESSIONS_FILE"
mkdir -p "$SESSIONS_DIR"
```

- [ ] **Step 2: Update next_port to use 3001–3010 range**

Replace the `next_port` function:

```bash
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
```

- [ ] **Step 3: Remove old functions, add replacements**

**Keep these existing functions** (they are reused by the new code): `slugify`, `registry_add`, `registry_end`, `registry_prune`, `next_port` (updated in step 2), `find_session_by_cwd`.

**Remove these functions entirely:** `db_prepare`, `sync_env_var`, `patch_database_yml`, `setup_session`, `launch_tmux`, `cmd_fix`.

**Replace `launch_tmux`** with the new Docker-aware version below. **Add `setup_worktree`** as a new function:

```bash
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

  # Pane 2 (bottom-left): shell inside container
  tmux select-pane -t "$session_name:.0"
  tmux split-window -v -t "$session_name" -c "$worktree_path" -l 30%
  tmux send-keys -t "$session_name" "docker compose -p $project -f $worktree_path/docker-compose.yml exec app bash" Enter

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$session_name"
  else
    exec tmux attach -t "$session_name"
  fi
}
```

- [ ] **Step 4: Commit**

```bash
git add ws
git commit -m "refactor: rewrite ws helpers for Docker — remove all native Postgres/patching code"
```

---

### Task 6: Rewrite ws — cmd_attach

**Files:**
- Modify: `ws` (the `cmd_attach` function)

**Context:** The attach command keeps the same argument parsing and branch resolution (--pr, --branch, --new) but replaces all database and patching logic with Docker Compose lifecycle. Key change: instead of `db_clone` + `setup_session` + patching, it now calls `generate_compose` + `compose_up` + `setup_worktree`.

- [ ] **Step 1: Rewrite cmd_attach**

Replace the entire `cmd_attach` function with:

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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n /Users/lancefoley/code/wescom-session/ws`

Expected: No output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add ws
git commit -m "feat: rewrite cmd_attach for Docker Compose lifecycle"
```

---

### Task 7: Rewrite ws — cmd_list

**Files:**
- Modify: `ws` (the `cmd_list` function)

**Context:** Replace database orphan checking with Docker container status display.

- [ ] **Step 1: Rewrite cmd_list**

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
```

- [ ] **Step 2: Commit**

```bash
git add ws
git commit -m "feat: rewrite cmd_list with Docker container status"
```

---

### Task 8: Rewrite ws — cmd_end

**Files:**
- Modify: `ws` (the `cmd_end` function)

**Context:** Replace `db_drop` with `docker compose down -v`. Remove the separate "drop database?" prompt — `down -v` handles everything.

- [ ] **Step 1: Rewrite cmd_end**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add ws
git commit -m "feat: rewrite cmd_end with docker compose down"
```

---

### Task 9: Add ws rebuild command

**Files:**
- Modify: `ws` (add `cmd_rebuild` function and wire it into the case statement)

**Context:** New command that builds the golden base image. Copies dependency files from the main wescomapp repo into a temporary build context, runs `docker build`, tags as `wescomapp-dev:latest`.

- [ ] **Step 1: Add cmd_rebuild function**

Add this function before the `usage` function:

```bash
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
```

- [ ] **Step 2: Wire into case statement and usage**

Update the case statement at the bottom of `ws`:

```bash
case "${1:-}" in
  attach)  shift; cmd_attach "$@" ;;
  list)    cmd_list ;;
  end)     shift; cmd_end "$@" ;;
  rebuild) cmd_rebuild ;;
  exec)    shift; cmd_exec "$@" ;;
  -h|--help|help) usage ;;
  *)       usage ;;
esac
```

Update the usage function:

```bash
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
```

- [ ] **Step 3: Commit**

```bash
git add ws
git commit -m "feat: add ws rebuild command to build golden base image"
```

---

### Task 10: Add ws exec command

**Files:**
- Modify: `ws` (add `cmd_exec` function)

**Context:** Convenience command to run commands inside the session's app container. Detects the current session from `$PWD`, then runs `docker compose exec app <command>`.

- [ ] **Step 1: Add cmd_exec function**

Add before the usage function:

```bash
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
```

- [ ] **Step 2: Verify the case statement includes exec**

Already wired in Task 9, Step 2. Verify:
```bash
grep "exec)" /Users/lancefoley/code/wescom-session/ws
```

Expected: `exec)    shift; cmd_exec "$@" ;;`

- [ ] **Step 3: Commit**

```bash
git add ws
git commit -m "feat: add ws exec command for running commands in container"
```

---

### Task 11: Update install.sh

**Files:**
- Modify: `install.sh`

**Context:** Replace PostgreSQL tool prerequisites (`psql`, `createdb`, `dropdb`) with `docker`. Add a check for OrbStack or Docker Desktop. Keep `git`, `jq`, `gh`, `tmux`, `claude`.

- [ ] **Step 1: Rewrite install.sh**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat: update install.sh — replace Postgres prereqs with Docker/OrbStack"
```

---

### Task 12: Remove lib/database.sh and clean up

**Files:**
- Remove: `lib/database.sh`

**Context:** All functions in `database.sh` (`db_clone`, `db_drop`, `db_exists`, `db_list_session_dbs`) are replaced by Docker container lifecycle. The file is no longer sourced by `ws`.

- [ ] **Step 1: Remove the file**

```bash
git rm lib/database.sh
```

- [ ] **Step 2: Verify ws doesn't reference database.sh**

Run: `grep -n "database.sh" /Users/lancefoley/code/wescom-session/ws`

Expected: No matches.

Run: `grep -n "db_clone\|db_drop\|db_exists\|db_list_session_dbs\|db_prepare\|PG_USER\|PG_BASE_DB" /Users/lancefoley/code/wescom-session/ws`

Expected: No matches.

- [ ] **Step 3: Verify full script parses cleanly**

Run: `bash -n /Users/lancefoley/code/wescom-session/ws`

Expected: No output (clean parse).

- [ ] **Step 4: Commit**

```bash
git rm lib/database.sh
git commit -m "chore: remove lib/database.sh — replaced by Docker lifecycle"
```

---

### Task 13: End-to-end verification

**Context:** Verify the complete workflow works. This requires OrbStack installed and running.

- [ ] **Step 1: Install OrbStack (if not already)**

Run: `brew install orbstack`

Start OrbStack from Applications if not running.

- [ ] **Step 2: Run install.sh**

Run: `cd /Users/lancefoley/code/wescom-session && bash install.sh`

Expected: All prerequisites found, ws installed.

- [ ] **Step 3: Build the base image**

Run: `ws rebuild`

Expected: Image builds successfully. Output shows `wescomapp-dev:latest` with size.

Verify: `docker image ls wescomapp-dev`

- [ ] **Step 4: Create a test session**

Run: `ws attach --new "test docker setup"`

Expected:
- Worktree created at `~/code/wescom-sessions/test-docker-setup/`
- Containers start (db + app + worker)
- Database initialized from latest.dump
- Migrations run
- Passwords reset
- tmux session opens with logs + shell + Claude Code
- Browser can access `http://localhost:3001` (or whichever port assigned)

- [ ] **Step 5: Verify ws list shows the session**

Run (in a separate terminal): `ws list`

Expected: Shows the test session with branch, port, and "running" status.

- [ ] **Step 6: Verify ws exec works**

Run (from inside the worktree): `ws exec rails runner "puts User.count"`

Expected: Outputs a number (user count from the restored dump).

- [ ] **Step 7: Verify live reload**

Edit a view file in `~/code/wescom-sessions/test-docker-setup/` and refresh the browser.

Expected: Changes visible immediately.

- [ ] **Step 8: Tear down the test session**

Run: `ws end --branch test-docker-setup`

Expected:
- Prompted to push (decline for test)
- Containers stopped, volumes removed
- Prompted to remove worktree (accept)
- Session marked as ended

Verify: `ws list` shows no active sessions. `docker compose -p ws-test-docker-setup ps` shows nothing.

- [ ] **Step 9: Commit any fixes discovered during testing**

If any adjustments were needed, commit them:
```bash
git add -A
git commit -m "fix: adjustments from end-to-end testing"
```
