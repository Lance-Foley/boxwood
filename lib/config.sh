#!/usr/bin/env bash
# Project discovery + .ws/config.yml access.
#
# YAML is converted to JSON once (via yq) and queried with jq. Sets the globals
# REPO_ROOT, REPO, CONFIG, CONFIG_JSON.

# Per-user developer preferences (~/.ws/config.yml). Defaults to empty so ucfg
# queries are always safe even when the file is absent.
USER_CONFIG_JSON='{}'

# Resolve the *main* repository root, even when invoked from inside a session
# worktree (worktrees share the main repo's common git dir).
load_repo_context() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || true
  if [[ -z "$common" ]]; then
    error "Not inside a git repository. cd into a repo first."
    exit 1
  fi
  REPO_ROOT=$(dirname "$common")
  REPO=$(basename "$REPO_ROOT")
  CONFIG="$REPO_ROOT/.ws/config.yml"
  load_user_config
}

# Convert the YAML config to JSON once and cache it in CONFIG_JSON.
load_config() {
  if [[ ! -f "$CONFIG" ]]; then
    error "No .ws/config.yml found in $REPO_ROOT"
    error "Run 'ws init' to scaffold one."
    exit 1
  fi
  CONFIG_JSON=$(yq -o=json '.' "$CONFIG" 2>/dev/null) || {
    error "Could not parse $CONFIG (invalid YAML?)"
    exit 1
  }
}

# Load the per-user developer preferences (~/.ws/config.yml) into
# USER_CONFIG_JSON. Optional and best-effort: never exits, falls back to '{}'.
load_user_config() {
  local user_config="$WS_HOME/config.yml"
  [[ -f "$user_config" ]] || return 0
  local json
  json=$(yq -o=json '.' "$user_config" 2>/dev/null) || json=""
  USER_CONFIG_JSON="${json:-{}}"
}

# Load repo context AND config — for commands that need the recipe.
require_config() {
  load_repo_context
  load_config
}

# Read a jq expression from the config; prints "" for null/missing.
cfg() {
  echo "$CONFIG_JSON" | jq -r "$1 // empty" 2>/dev/null
}

# Read a jq expression with a fallback default.
cfg_default() {
  local val
  val=$(cfg "$1")
  echo "${val:-$2}"
}

# Read a jq expression from the per-user config; prints "" for null/missing.
ucfg() {
  echo "$USER_CONFIG_JSON" | jq -r "$1 // empty" 2>/dev/null
}

# Read a per-user jq expression with a fallback default.
ucfg_default() {
  local val
  val=$(ucfg "$1")
  echo "${val:-$2}"
}

# True if the config declares a database block.
has_db() {
  [[ -n "$(echo "$CONFIG_JSON" | jq -c '.db // empty' 2>/dev/null)" ]]
}
