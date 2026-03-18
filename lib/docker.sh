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
# Note: Docker Compose v2.21+ uses NDJSON (one object per line), not arrays.
# We use head -1 and check for non-empty output.
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
    # Follow app logs until "Database ready." appears, with 5-minute timeout.
    # Run log-following in a background process so we can kill it on timeout.
    local log_pid
    docker compose -p "$project" logs -f app 2>&1 | while IFS= read -r line; do
      echo "  $line"
      if [[ "$line" == *"Database ready."* ]]; then
        break
      fi
    done &
    log_pid=$!

    # Wait up to 5 minutes for the log-following to finish
    local waited=0
    while kill -0 "$log_pid" 2>/dev/null && [[ $waited -lt 300 ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$log_pid" 2>/dev/null; then
      kill "$log_pid" 2>/dev/null
      error "Database initialization timed out after 5 minutes. Check: docker compose -p $project logs app"
    else
      wait "$log_pid" 2>/dev/null
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
