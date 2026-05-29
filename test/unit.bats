#!/usr/bin/env bats
# Tier-1 unit tests for boxwood's pure-logic shell functions.
#
# These exercise the engine's pure / jq-backed helpers in isolation by sourcing
# the (main-guarded) `ws` script. Docker- and yq-dependent functions live in
# docker.bats and config.bats respectively.

load 'helper'

setup() {
  load_ws
}

# ─── slugify ──────────────────────────────────────────────────────────────────

@test "slugify: lowercases" {
  run slugify "MixedCase"
  [ "$status" -eq 0 ]
  [ "$output" = "mixedcase" ]
}

@test "slugify: spaces become dashes" {
  run slugify "hello world"
  [ "$output" = "hello-world" ]
}

@test "slugify: slashes become dashes" {
  run slugify "feature/login"
  [ "$output" = "feature-login" ]
}

@test "slugify: special characters become dashes" {
  run slugify "fix#123!@&bug"
  [ "$output" = "fix-123-bug" ]
}

@test "slugify: collapses repeated separators" {
  run slugify "a   b___c///d"
  [ "$output" = "a-b-c-d" ]
}

@test "slugify: trims leading and trailing dashes" {
  run slugify "---trim me---"
  [ "$output" = "trim-me" ]
}

@test "slugify: caps output at 50 characters" {
  long="$(printf 'a%.0s' {1..80})"
  run slugify "$long"
  [ "${#output}" -eq 50 ]
}

@test "slugify: combined real-world description" {
  run slugify "Add OAuth2 Login (Google/GitHub)!"
  [ "$output" = "add-oauth2-login-google-github" ]
}

# ─── registry_add ───────────────────────────────────────────────────────────

@test "registry_add: appends a session with active status and all fields" {
  echo '[]' > "$REGISTRY"
  registry_add "myrepo" "feat-x" "ws-myrepo-feat-x" 3000 "/sessions/feat-x" 42

  [ "$(jq 'length' "$REGISTRY")" -eq 1 ]
  [ "$(jq -r '.[0].repo'    "$REGISTRY")" = "myrepo" ]
  [ "$(jq -r '.[0].branch'  "$REGISTRY")" = "feat-x" ]
  [ "$(jq -r '.[0].project' "$REGISTRY")" = "ws-myrepo-feat-x" ]
  [ "$(jq -r '.[0].port'    "$REGISTRY")" = "3000" ]
  [ "$(jq -r '.[0].path'    "$REGISTRY")" = "/sessions/feat-x" ]
  [ "$(jq -r '.[0].pr'      "$REGISTRY")" = "42" ]
  [ "$(jq -r '.[0].status'  "$REGISTRY")" = "active" ]
}

@test "registry_add: defaults pr to null when omitted" {
  echo '[]' > "$REGISTRY"
  registry_add "myrepo" "feat-y" "ws-myrepo-feat-y" 3001 "/sessions/feat-y"
  [ "$(jq -r '.[0].pr' "$REGISTRY")" = "null" ]
}

@test "registry_add: appends without clobbering existing entries" {
  echo '[]' > "$REGISTRY"
  registry_add "r" "a" "p-a" 3000 "/a"
  registry_add "r" "b" "p-b" 3001 "/b"
  [ "$(jq 'length' "$REGISTRY")" -eq 2 ]
  [ "$(jq -r '.[1].branch' "$REGISTRY")" = "b" ]
}

# ─── registry_end ───────────────────────────────────────────────────────────

@test "registry_end: flips only the matching session to ended" {
  echo '[]' > "$REGISTRY"
  registry_add "r" "a" "p-a" 3000 "/a"
  registry_add "r" "b" "p-b" 3001 "/b"

  registry_end "r" "a"

  [ "$(jq -r '.[] | select(.branch=="a") | .status' "$REGISTRY")" = "ended" ]
  [ "$(jq -r '.[] | select(.branch=="b") | .status' "$REGISTRY")" = "active" ]
}

@test "registry_end: only matches the same repo" {
  cat > "$REGISTRY" <<'JSON'
[
 {"repo":"r1","branch":"shared","status":"active"},
 {"repo":"r2","branch":"shared","status":"active"}
]
JSON
  registry_end "r1" "shared"
  [ "$(jq -r '.[] | select(.repo=="r1") | .status' "$REGISTRY")" = "ended" ]
  [ "$(jq -r '.[] | select(.repo=="r2") | .status' "$REGISTRY")" = "active" ]
}

# ─── registry_prune ─────────────────────────────────────────────────────────

@test "registry_prune: keeps active sessions, keeps recent-ended, drops old-ended" {
  local old recent
  old="$(date -v-60d +'%Y-%m-%d' 2>/dev/null || date -d '60 days ago' +'%Y-%m-%d')"
  recent="$(date +'%Y-%m-%d')"
  cat > "$REGISTRY" <<JSON
[
 {"repo":"r","branch":"old-ended","status":"ended","started":"$old 10:00"},
 {"repo":"r","branch":"recent-ended","status":"ended","started":"$recent 10:00"},
 {"repo":"r","branch":"old-active","status":"active","started":"$old 10:00"}
]
JSON
  registry_prune

  local branches
  branches="$(jq -rc '[.[].branch] | sort' "$REGISTRY")"
  [ "$branches" = '["old-active","recent-ended"]' ]
}

# ─── next_port ──────────────────────────────────────────────────────────────

@test "next_port: returns the low end of the range when nothing is used" {
  export CONFIG_JSON='{"ports":{"range":[3000,3005]}}'
  echo '[]' > "$REGISTRY"
  run next_port
  [ "$status" -eq 0 ]
  [ "$output" = "3000" ]
}

@test "next_port: returns the lowest FREE port in the range" {
  export CONFIG_JSON='{"ports":{"range":[3000,3005]}}'
  cat > "$REGISTRY" <<'JSON'
[
 {"status":"active","port":3000},
 {"status":"active","port":3001},
 {"status":"active","port":3003}
]
JSON
  run next_port
  [ "$status" -eq 0 ]
  [ "$output" = "3002" ]
}

@test "next_port: ignores ports held by ended sessions" {
  export CONFIG_JSON='{"ports":{"range":[3000,3005]}}'
  cat > "$REGISTRY" <<'JSON'
[
 {"status":"ended","port":3000},
 {"status":"active","port":3001}
]
JSON
  run next_port
  [ "$status" -eq 0 ]
  [ "$output" = "3000" ]
}

@test "next_port: falls back to default range when config omits it" {
  export CONFIG_JSON='{}'
  echo '[]' > "$REGISTRY"
  run next_port
  [ "$status" -eq 0 ]
  [ "$output" = "3000" ]   # cfg_default '.ports.range[0]' 3000
}

@test "next_port: errors and returns nonzero when the range is exhausted" {
  export CONFIG_JSON='{"ports":{"range":[3000,3001]}}'
  cat > "$REGISTRY" <<'JSON'
[
 {"status":"active","port":3000},
 {"status":"active","port":3001}
]
JSON
  run next_port
  [ "$status" -ne 0 ]
  [[ "$output" == *"All session ports"* ]]
}

# ─── find_session_by_cwd ──────────────────────────────────────────────────────

@test "find_session_by_cwd: returns branch whose path prefixes the cwd" {
  cat > "$REGISTRY" <<'JSON'
[
 {"status":"active","branch":"feat-a","path":"/sessions/repo/feat-a"},
 {"status":"active","branch":"feat-b","path":"/sessions/repo/feat-b"}
]
JSON
  run find_session_by_cwd "/sessions/repo/feat-b/app/models"
  [ "$status" -eq 0 ]
  [ "$output" = "feat-b" ]
}

@test "find_session_by_cwd: exact path match works" {
  cat > "$REGISTRY" <<'JSON'
[{"status":"active","branch":"feat-a","path":"/sessions/repo/feat-a"}]
JSON
  run find_session_by_cwd "/sessions/repo/feat-a"
  [ "$output" = "feat-a" ]
}

@test "find_session_by_cwd: returns nothing for an unrelated cwd" {
  cat > "$REGISTRY" <<'JSON'
[{"status":"active","branch":"feat-a","path":"/sessions/repo/feat-a"}]
JSON
  run find_session_by_cwd "/somewhere/else"
  [ -z "$output" ]
}

@test "find_session_by_cwd: ignores ended sessions" {
  cat > "$REGISTRY" <<'JSON'
[{"status":"ended","branch":"feat-a","path":"/sessions/repo/feat-a"}]
JSON
  run find_session_by_cwd "/sessions/repo/feat-a"
  [ -z "$output" ]
}

# ─── generate_compose ─────────────────────────────────────────────────────────

@test "generate_compose: substitutes all four template tokens" {
  REPO_ROOT="$WS_HOME/repo"
  mkdir -p "$REPO_ROOT/.ws"
  export CONFIG_JSON='{}'   # so cfg_default falls back to the default template path

  cat > "$REPO_ROOT/.ws/docker-compose.template.yml" <<'YML'
services:
  app:
    build: { context: __REPO_ROOT__ }
    volumes: ["__WORKTREE_PATH__:/app"]
    ports: ["__HOST_PORT__:3000"]
    environment: { DB_INIT: __DB_INIT__ }
YML

  local wt="$WS_HOME/wt"
  mkdir -p "$wt"
  generate_compose "$wt" 3007 true

  local out="$wt/docker-compose.yml"
  [ -f "$out" ]
  grep -q "context: $REPO_ROOT" "$out"
  grep -q "$wt:/app" "$out"
  grep -q '"3007:3000"' "$out"
  grep -q "DB_INIT: true" "$out"
  # No raw tokens should survive substitution.
  ! grep -q '__WORKTREE_PATH__\|__REPO_ROOT__\|__HOST_PORT__\|__DB_INIT__' "$out"
}

@test "generate_compose: respects a custom template path from config" {
  REPO_ROOT="$WS_HOME/repo"
  mkdir -p "$REPO_ROOT/custom"
  export CONFIG_JSON='{"compose":{"template":"custom/my-template.yml"}}'

  cat > "$REPO_ROOT/custom/my-template.yml" <<'YML'
port: __HOST_PORT__
YML

  local wt="$WS_HOME/wt2"
  mkdir -p "$wt"
  generate_compose "$wt" 4242 false
  grep -q "port: 4242" "$wt/docker-compose.yml"
}

# NOTE: the confirm() tests moved to test/colors.bats when confirm() gained a
# destructive-aware default ('Y' benign / 'N' destructive). See that file.
