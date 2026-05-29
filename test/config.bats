#!/usr/bin/env bats
# Unit tests for lib/config.sh — YAML→JSON parsing and the cfg/ucfg accessors.
#
# These require `yq` (the engine uses it to convert YAML to JSON). Without yq the
# tests skip with a clear message rather than failing.

load 'helper'

setup() {
  load_ws
  require_yq
}

# ─── load_config / cfg / cfg_default ──────────────────────────────────────────

write_repo_config() {
  CONFIG="$WS_HOME/repo-config.yml"
  cat > "$CONFIG" <<'YML'
main_branch: develop
image:
  name: myapp:latest
  dockerfile: .ws/Dockerfile
ports:
  range: [4000, 4002]
db:
  restore_command: /usr/local/bin/db-init.sh
YML
}

@test "load_config: parses YAML into CONFIG_JSON" {
  write_repo_config
  load_config
  [ -n "$CONFIG_JSON" ]
  [ "$(echo "$CONFIG_JSON" | jq -r '.main_branch')" = "develop" ]
}

@test "cfg: reads a nested scalar" {
  write_repo_config
  load_config
  run cfg '.image.name'
  [ "$output" = "myapp:latest" ]
}

@test "cfg: prints empty for a missing key" {
  write_repo_config
  load_config
  run cfg '.does.not.exist'
  [ -z "$output" ]
}

@test "cfg_default: returns the configured value when present" {
  write_repo_config
  load_config
  run cfg_default '.main_branch' 'main'
  [ "$output" = "develop" ]
}

@test "cfg_default: falls back to the default when absent" {
  write_repo_config
  load_config
  run cfg_default '.compose.app_service' 'app'
  [ "$output" = "app" ]
}

@test "cfg_default: reads an array element (port range)" {
  write_repo_config
  load_config
  run cfg_default '.ports.range[0]' 3000
  [ "$output" = "4000" ]
  run cfg_default '.ports.range[1]' 3005
  [ "$output" = "4002" ]
}

# ─── has_db ───────────────────────────────────────────────────────────────────

@test "has_db: true when a db block is present" {
  write_repo_config
  load_config
  run has_db
  [ "$status" -eq 0 ]
}

@test "has_db: false when the db block is absent" {
  CONFIG="$WS_HOME/no-db.yml"
  cat > "$CONFIG" <<'YML'
main_branch: main
image:
  name: app:latest
YML
  load_config
  run has_db
  [ "$status" -ne 0 ]
}

# ─── load_config error handling ───────────────────────────────────────────────

@test "load_config: errors out when the config file is missing" {
  CONFIG="$WS_HOME/missing.yml"
  REPO_ROOT="$WS_HOME"
  run load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"No .ws/config.yml"* ]]
}

# ─── load_user_config / ucfg / ucfg_default ───────────────────────────────────

write_user_config() {
  cat > "$WS_HOME/config.yml" <<'YML'
editor: vim
gui_editor: Zed
assistant:
  command: ""
  skip_permissions: true
YML
}

@test "load_user_config: populates USER_CONFIG_JSON from \$WS_HOME/config.yml" {
  write_user_config
  load_user_config
  [ "$(echo "$USER_CONFIG_JSON" | jq -r '.editor')" = "vim" ]
}

@test "load_user_config: defaults to '{}' when no user config exists" {
  load_user_config
  [ "$USER_CONFIG_JSON" = '{}' ]
}

@test "ucfg: reads a per-user scalar" {
  write_user_config
  load_user_config
  run ucfg '.editor'
  [ "$output" = "vim" ]
}

@test "ucfg: reads a nested per-user boolean" {
  write_user_config
  load_user_config
  run ucfg '.assistant.skip_permissions'
  [ "$output" = "true" ]
}

@test "ucfg: empty for a present-but-blank value" {
  write_user_config
  load_user_config
  run ucfg '.assistant.command'
  [ -z "$output" ]
}

@test "ucfg_default: falls back when the key is missing" {
  write_user_config
  load_user_config
  run ucfg_default '.theme' 'dark'
  [ "$output" = "dark" ]
}

@test "ucfg_default: returns the user value when present" {
  write_user_config
  load_user_config
  run ucfg_default '.gui_editor' 'none'
  [ "$output" = "Zed" ]
}

# ─── resolve_assistant_command (per-user assistant resolution) ────────────────
# Documented contract in ws:
#   key absent          -> "claude"
#   key present, blank  -> ""        (plain shell)
#   key present, value  -> that value

@test "resolve_assistant_command: defaults to claude when the key is absent" {
  cat > "$WS_HOME/config.yml" <<'YML'
editor: vim
YML
  load_user_config
  run resolve_assistant_command
  [ "$output" = "claude" ]
}

@test "resolve_assistant_command: blank command -> empty (plain shell)" {
  cat > "$WS_HOME/config.yml" <<'YML'
assistant:
  command: ""
YML
  load_user_config
  run resolve_assistant_command
  [ -z "$output" ]
}

@test "resolve_assistant_command: explicit value is returned verbatim" {
  cat > "$WS_HOME/config.yml" <<'YML'
assistant:
  command: aider
YML
  load_user_config
  run resolve_assistant_command
  [ "$output" = "aider" ]
}
