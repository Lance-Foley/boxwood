# Shared bats helpers for boxwood unit tests.
#
# Loaded by every *.bats file. Provides:
#   load_ws            – set up an isolated WS_HOME and source the (sourceable) ws engine
#   stub_docker        – put a fake `docker` on PATH whose behavior is driven by env vars
#   require_yq         – skip a test (with a clear message) when yq is unavailable
#
# The ws script's main-guard (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`) means
# sourcing it defines all functions WITHOUT dispatching a command.

WS_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WS_BIN="$WS_ROOT/ws"

# Source the engine into the current shell with an isolated home.
# Each test gets its own WS_HOME (and therefore its own REGISTRY).
load_ws() {
  export WS_HOME
  WS_HOME="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/wshome.XXXXXX")"
  # shellcheck disable=SC1090
  source "$WS_BIN"
}

# Install a fake `docker` executable on PATH. Its output is controlled by:
#   DOCKER_RUNNING=1   -> `docker compose ps --status running` yields a row
#   DOCKER_ANY=1       -> `docker compose ps` (no status filter) yields a row
#   DOCKER_VOLUMES=1   -> `docker volume ls -q --filter ...` yields a volume name
# Anything else prints nothing (the real-world "none"/empty case).
stub_docker() {
  STUB_BIN="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/stubbin.XXXXXX")"
  cat > "$STUB_BIN/docker" <<'SH'
#!/usr/bin/env bash
# Minimal docker stub for boxwood unit tests.
if [[ "$1" == "compose" ]]; then
  # Find whether a status filter is present anywhere in the args.
  has_running_filter=0
  for a in "$@"; do [[ "$a" == "running" ]] && has_running_filter=1; done
  # Is this a `ps` invocation?
  is_ps=0
  for a in "$@"; do [[ "$a" == "ps" ]] && is_ps=1; done
  if [[ "$is_ps" == "1" ]]; then
    if [[ "$has_running_filter" == "1" ]]; then
      [[ -n "${DOCKER_RUNNING:-}" ]] && echo '{"Name":"stub","State":"running"}'
    else
      { [[ -n "${DOCKER_RUNNING:-}" ]] || [[ -n "${DOCKER_ANY:-}" ]]; } && echo '{"Name":"stub","State":"exited"}'
    fi
  fi
  exit 0
fi
if [[ "$1" == "volume" && "$2" == "ls" ]]; then
  [[ -n "${DOCKER_VOLUMES:-}" ]] && echo 'someproject_pgdata'
  exit 0
fi
exit 0
SH
  chmod +x "$STUB_BIN/docker"
  export PATH="$STUB_BIN:$PATH"
}

# Skip the current test (with a clear reason) unless yq is installed.
require_yq() {
  command -v yq >/dev/null 2>&1 || skip "yq not installed (brew install yq) — config-parsing tests need it"
}
