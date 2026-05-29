#!/usr/bin/env bash
# Project discovery + .ws/config.yml access.
#
# YAML is converted to JSON once (via Ruby's stdlib — no extra deps) and queried
# with jq. Sets the globals REPO_ROOT, REPO, CONFIG, CONFIG_JSON.

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
}

# Convert the YAML config to JSON once and cache it in CONFIG_JSON.
load_config() {
  if [[ ! -f "$CONFIG" ]]; then
    error "No .ws/config.yml found in $REPO_ROOT"
    error "Run 'ws init' to scaffold one."
    exit 1
  fi
  CONFIG_JSON=$(ruby -ryaml -rjson -e \
    'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$CONFIG" 2>/dev/null) || {
    error "Could not parse $CONFIG (invalid YAML?)"
    exit 1
  }
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

# True if the config declares a database block.
has_db() {
  [[ -n "$(echo "$CONFIG_JSON" | jq -c '.db // empty' 2>/dev/null)" ]]
}
