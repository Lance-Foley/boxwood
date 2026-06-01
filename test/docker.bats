#!/usr/bin/env bats
# Unit tests for the docker-backed helpers in lib/docker.sh.
#
# `docker` is replaced by a PATH shim (see helper.bash::stub_docker) whose canned
# output is driven by env vars, so these run with no real Docker daemon.

load 'helper'

setup() {
  load_ws
  stub_docker
}

# ─── compose_status ───────────────────────────────────────────────────────────

@test "compose_status: running when a running container is reported" {
  export DOCKER_RUNNING=1
  run compose_status "ws-repo-feat"
  [ "$output" = "running" ]
}

@test "compose_status: stopped when containers exist but none are running" {
  export DOCKER_ANY=1
  run compose_status "ws-repo-feat"
  [ "$output" = "stopped" ]
}

@test "compose_status: none when there are no containers" {
  run compose_status "ws-repo-feat"
  [ "$output" = "none" ]
}

# ─── detect_session_state ─────────────────────────────────────────────────────
# Mapping under test:
#   running                          -> resume
#   running + app_service unhealthy  -> restart   (half-dead stack → repair)
#   running + app_service healthy    -> resume
#   stopped                          -> restart
#   none + volumes present           -> restart
#   none + no volumes                -> first_run

@test "detect_session_state: running -> resume" {
  export DOCKER_RUNNING=1
  run detect_session_state "ws-repo-feat"
  [ "$output" = "resume" ]
}

@test "detect_session_state: running but app_service unhealthy -> restart" {
  export DOCKER_RUNNING=1 DOCKER_APP_UNHEALTHY=1
  run detect_session_state "ws-repo-feat" "app"
  [ "$output" = "restart" ]
}

@test "detect_session_state: running and app_service healthy -> resume" {
  export DOCKER_RUNNING=1
  run detect_session_state "ws-repo-feat" "app"
  [ "$output" = "resume" ]
}

@test "detect_session_state: stopped -> restart" {
  export DOCKER_ANY=1
  run detect_session_state "ws-repo-feat"
  [ "$output" = "restart" ]
}

@test "detect_session_state: none + volumes -> restart" {
  export DOCKER_VOLUMES=1
  run detect_session_state "ws-repo-feat"
  [ "$output" = "restart" ]
}

@test "detect_session_state: none + no volumes -> first_run" {
  run detect_session_state "ws-repo-feat"
  [ "$output" = "first_run" ]
}

# ─── project_has_volumes ──────────────────────────────────────────────────────

@test "project_has_volumes: true when the stub reports a volume" {
  export DOCKER_VOLUMES=1
  run project_has_volumes "ws-repo-feat"
  [ "$status" -eq 0 ]
}

@test "project_has_volumes: false when no volume exists" {
  run project_has_volumes "ws-repo-feat"
  [ "$status" -ne 0 ]
}

# ─── compose_project_name ─────────────────────────────────────────────────────

@test "compose_project_name: ws-prefixed repo+branch slug" {
  run compose_project_name "myrepo" "feat-x"
  [ "$output" = "ws-myrepo-feat-x" ]
}

# ─── compose_status_display ───────────────────────────────────────────────────

@test "compose_status_display: contains the running word" {
  export DOCKER_RUNNING=1
  run compose_status_display "ws-repo-feat"
  [[ "$output" == *running* ]]
}

@test "compose_status_display: shows 'no containers' for none" {
  run compose_status_display "ws-repo-feat"
  [[ "$output" == *"no containers"* ]]
}

# ─── service_health_ok (pure JSON parser behind service_healthy) ───────────────
# Fed one `docker compose ps --format json` object; no docker call involved.

@test "service_health_ok: running + healthy is OK" {
  run service_health_ok '{"Name":"db","State":"running","Health":"healthy"}'
  [ "$status" -eq 0 ]
}

@test "service_health_ok: running with no Health field is OK (no healthcheck)" {
  run service_health_ok '{"Name":"db","State":"running"}'
  [ "$status" -eq 0 ]
}

@test "service_health_ok: running but starting is rejected" {
  run service_health_ok '{"Name":"db","State":"running","Health":"starting"}'
  [ "$status" -ne 0 ]
}

@test "service_health_ok: running but unhealthy is rejected" {
  run service_health_ok '{"Name":"db","State":"running","Health":"unhealthy"}'
  [ "$status" -ne 0 ]
}

@test "service_health_ok: non-running state is rejected" {
  run service_health_ok '{"Name":"db","State":"exited"}'
  [ "$status" -ne 0 ]
}

@test "service_health_ok: empty input is rejected" {
  run service_health_ok ""
  [ "$status" -ne 0 ]
}

@test "service_health_ok: empty-array string is rejected" {
  run service_health_ok "[]"
  [ "$status" -ne 0 ]
}

# ─── compose_up failure is recoverable (returns, does not exit) ─────────────────
# start_session relies on catching a failed compose_up to escalate. If compose_up
# `exit`ed, the whole process would die and no escalation could happen.

@test "compose_up: returns non-zero (does not exit the shell) when 'up' fails" {
  export DOCKER_UP_FAIL=1
  generate_compose() { :; }   # skip template rendering; we only test the up path
  # If compose_up exits, the subshell dies before the marker echo prints.
  out=$( compose_up proj /wt 3000 restart 2>/dev/null; echo "AFTER:$?" )
  [[ "$out" == *"AFTER:1"* ]]
}

# ─── start_session escalation ──────────────────────────────────────────────────
# Drives the orchestration logic with compose_up/compose_down/project_has_volumes
# overridden, so the branch behavior is observable via emitted markers.

@test "start_session: first compose_up succeeds -> no down, no reinit" {
  compose_up()         { echo "up:$4"; return 0; }
  compose_down()       { echo "down"; }
  project_has_volumes(){ return 0; }
  run start_session proj /wt 3000 restart app
  [ "$status" -eq 0 ]
  [[ "$output" == *"up:restart"* ]]
  [[ "$output" != *"up:first_run"* ]]
  [[ "$output" != *"down"* ]]
}

@test "start_session: restart fails + volumes -> drops volume and reinits first_run" {
  compose_up()         { echo "up:$4"; [[ "$4" == "first_run" ]] && return 0 || return 1; }
  compose_down()       { echo "down"; }
  project_has_volumes(){ return 0; }
  run start_session proj /wt 3000 restart app
  [ "$status" -eq 0 ]
  [[ "$output" == *"up:restart"* ]]
  [[ "$output" == *"down"* ]]
  [[ "$output" == *"up:first_run"* ]]
}

@test "start_session: failure + no volumes -> returns 1, no reinit" {
  compose_up()         { echo "up:$4"; return 1; }
  compose_down()       { echo "down"; }
  project_has_volumes(){ return 1; }
  run start_session proj /wt 3000 restart app
  [ "$status" -eq 1 ]
  [[ "$output" == *"up:restart"* ]]
  [[ "$output" != *"down"* ]]
  [[ "$output" != *"up:first_run"* ]]
}
