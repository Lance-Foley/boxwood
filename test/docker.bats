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
#   running                 -> resume
#   stopped                 -> restart
#   none + volumes present  -> restart
#   none + no volumes       -> first_run

@test "detect_session_state: running -> resume" {
  export DOCKER_RUNNING=1
  run detect_session_state "ws-repo-feat"
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
