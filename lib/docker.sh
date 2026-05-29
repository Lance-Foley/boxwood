#!/usr/bin/env bash
# Docker Compose session helpers (stack-agnostic).
# Relies on globals set by lib/config.sh: REPO_ROOT, CONFIG_JSON, and cfg().

# Check that a project's golden base image exists.
image_exists() {
  docker image inspect "$1" > /dev/null 2>&1
}

# Generate a docker-compose.yml from the repo's template for a specific session.
generate_compose() {
  local worktree_path="$1" host_port="$2" db_init="$3"

  local template
  template="$REPO_ROOT/$(cfg_default '.compose.template' '.ws/docker-compose.template.yml')"
  if [[ ! -f "$template" ]]; then
    error "Compose template not found: $template"
    exit 1
  fi

  local output="$worktree_path/docker-compose.yml"
  sed \
    -e "s|__WORKTREE_PATH__|${worktree_path}|g" \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__HOST_PORT__|${host_port}|g" \
    -e "s|__DB_INIT__|${db_init}|g" \
    "$template" > "$output"
}

# Compose project name for a repo + branch slug (lowercased, ws-prefixed).
# Includes the repo so projects never collide across repos.
compose_project_name() {
  local repo_slug="$1" branch_slug="$2"
  echo "ws-${repo_slug}-${branch_slug}"
}

# Running / stopped / none for a compose project.
# Docker Compose v2.21+ emits NDJSON (one object per line), so we head -1.
compose_status() {
  local project="$1"
  local running
  running=$(docker compose -p "$project" ps --status running --format json 2>/dev/null | head -1)
  if [[ -n "$running" && "$running" != "[]" ]]; then
    echo "running"; return 0
  fi
  local any
  any=$(docker compose -p "$project" ps --format json 2>/dev/null | head -1)
  if [[ -n "$any" && "$any" != "[]" ]]; then
    echo "stopped"; return 0
  fi
  echo "none"
}

# True if any named volume for this project exists (generic "has run before"
# signal — works regardless of whether the data volume is pgdata, mysql, etc.).
project_has_volumes() {
  local project="$1"
  [[ -n "$(docker volume ls -q --filter "name=^${project}_" 2>/dev/null | head -1)" ]]
}

# Detect session state: "first_run", "resume", or "restart".
detect_session_state() {
  local project="$1"
  local status
  status=$(compose_status "$project")
  case "$status" in
    running) echo "resume" ;;
    stopped) echo "restart" ;;
    none)
      if project_has_volumes "$project"; then echo "restart"; else echo "first_run"; fi
      ;;
  esac
}

# Start a compose stack and wait for healthchecks (handles first_run vs restart).
compose_up() {
  local project="$1" worktree_path="$2" host_port="$3" state="$4"
  local compose_file="$worktree_path/docker-compose.yml"

  local db_init="false"
  [[ "$state" == "first_run" ]] && db_init="true"

  generate_compose "$worktree_path" "$host_port" "$db_init"

  info "Starting containers (${state})..."
  if ! docker compose -p "$project" -f "$compose_file" up -d --wait --wait-timeout 600; then
    error "Containers did not become healthy in time."
    error "Check: docker compose -p $project logs"
    exit 1
  fi

  # After a first run, reset DB_INIT so a later container restart never re-inits.
  # Rewriting the env recreates the app container (now with DB_INIT=false).
  if [[ "$state" == "first_run" ]]; then
    generate_compose "$worktree_path" "$host_port" "false"
    docker compose -p "$project" -f "$compose_file" up -d --wait --wait-timeout 120 >/dev/null 2>&1 || true
  fi

  success "Containers running on port $host_port"
}

# Stop and remove a compose stack (including volumes).
compose_down() {
  local project="$1" worktree_path="$2"
  local compose_file="$worktree_path/docker-compose.yml"
  if [[ -f "$compose_file" ]]; then
    docker compose -p "$project" -f "$compose_file" down -v 2>/dev/null
  else
    docker compose -p "$project" down -v 2>/dev/null || true
  fi
}

# Colored status word for `ws list`.
compose_status_display() {
  local status
  status=$(compose_status "$1")
  case "$status" in
    running) echo -e "\033[0;32mrunning\033[0m" ;;
    stopped) echo -e "\033[1;33mstopped\033[0m" ;;
    none)    echo -e "\033[2mno containers\033[0m" ;;
  esac
}
