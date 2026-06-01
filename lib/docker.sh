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

  # Escape characters that are special on the REPLACEMENT side of sed's s|…|…|:
  # the delimiter (|), the whole-match backreference (&), and backslash (\).
  # Without this, a path containing any of them mis-substitutes or errors —
  # e.g. a repo cloned under a directory whose name contains '&'.
  local sed_esc='s/[&|\\]/\\&/g'
  local wt_e rr_e port_e init_e
  wt_e=$(printf '%s' "$worktree_path" | sed "$sed_esc")
  rr_e=$(printf '%s' "$REPO_ROOT"     | sed "$sed_esc")
  port_e=$(printf '%s' "$host_port"   | sed "$sed_esc")
  init_e=$(printf '%s' "$db_init"     | sed "$sed_esc")

  sed \
    -e "s|__WORKTREE_PATH__|${wt_e}|g" \
    -e "s|__REPO_ROOT__|${rr_e}|g" \
    -e "s|__HOST_PORT__|${port_e}|g" \
    -e "s|__DB_INIT__|${init_e}|g" \
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

# Decide, from a single `docker compose ps --format json` object (one service),
# whether that service is up AND healthy enough to run work against.
#
# Pure helper (no docker call) so it is unit-testable: feed it one NDJSON line.
# Accept when State is "running" AND Health is empty (no healthcheck declared)
# or "healthy". Reject "starting"/"unhealthy" (and any non-running State).
service_health_ok() {
  local json="$1" state health
  [[ -z "$json" || "$json" == "[]" ]] && return 1
  state=$(printf '%s' "$json"  | jq -r '.State  // empty' 2>/dev/null)
  health=$(printf '%s' "$json" | jq -r '.Health // empty' 2>/dev/null)
  [[ "$state" == "running" ]] || return 1
  [[ -z "$health" || "$health" == "healthy" ]]
}

# True if a specific service in a compose project has a running, healthy
# container. Mirrors compose_status's NDJSON `head -1` handling.
service_healthy() {
  local project="$1" service="$2" line
  line=$(docker compose -p "$project" ps "$service" --format json 2>/dev/null | head -1)
  service_health_ok "$line"
}

# True if any named volume for this project exists (generic "has run before"
# signal — works regardless of whether the data volume is pgdata, mysql, etc.).
project_has_volumes() {
  local project="$1"
  [[ -n "$(docker volume ls -q --filter "name=^${project}_" 2>/dev/null | head -1)" ]]
}

# Detect session state: "first_run", "resume", or "restart".
#
# A stack is only "resume" if it is safe to attach into as-is. When an
# app_service is given, a "running" project whose app container is NOT healthy is
# a half-dead stack (e.g. the worker is up but the app crashed on boot) and is
# demoted to "restart" so the caller repairs it rather than attaching into a dead
# app. Called with no app_service, the original status→state mapping is preserved.
detect_session_state() {
  local project="$1" app_service="${2:-}"
  local status
  status=$(compose_status "$project")
  case "$status" in
    running)
      if [[ -n "$app_service" ]] && ! service_healthy "$project" "$app_service"; then
        echo "restart"
      else
        echo "resume"
      fi
      ;;
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
    return 1
  fi

  # After a first run, reset DB_INIT so a later container restart never re-inits.
  # Rewriting the env recreates the app container (now with DB_INIT=false). This
  # recreate must NOT be silenced: if it fails, the app container is dead and
  # attaching into it would be a broken session — so fail loudly with logs.
  if [[ "$state" == "first_run" ]]; then
    generate_compose "$worktree_path" "$host_port" "false"
    if ! docker compose -p "$project" -f "$compose_file" up -d --wait --wait-timeout 120; then
      error "Container recreation failed after first-run init (DB_INIT=false)."
      local app_service; app_service=$(cfg_default '.compose.app_service' 'app')
      docker compose -p "$project" -f "$compose_file" logs --tail 50 "$app_service" >&2 || true
      return 1
    fi
  fi

  success "Containers running on port $host_port"
}

# Bring a session's stack up, self-healing a broken one. The git branch and
# worktree are NEVER touched — only containers and the DB volume.
#
# Escalation:
#   1. compose_up with the detected state (restart = DB_INIT false; the app
#      container is recreated and re-waited, repairing a crashed-on-boot stack).
#   2. If that fails and a DB volume exists, the data is assumed bad/uninitialized:
#      drop the volume and re-run a clean first-run init (DB_INIT true).
#   3. If that also fails (or there was no volume to reset), return non-zero so the
#      caller errors out with the logs compose_up already printed — no attaching
#      into a stack that cannot be brought up healthy.
start_session() {
  local project="$1" worktree_path="$2" port="$3" state="$4" app_service="$5"

  if compose_up "$project" "$worktree_path" "$port" "$state"; then
    return 0
  fi

  if [[ "$state" != "first_run" ]] && project_has_volumes "$project"; then
    warn "App did not come up healthy — reinitializing DB volume (branch & worktree untouched)."
    compose_down "$project" "$worktree_path"
    compose_up "$project" "$worktree_path" "$port" "first_run"
    return $?
  fi

  return 1
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
