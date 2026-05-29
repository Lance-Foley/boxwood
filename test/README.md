# boxwood tests

Tier-1 unit tests for boxwood's pure-logic and jq/yq-backed shell functions,
written with [bats-core](https://github.com/bats-core/bats-core).

## Running

```sh
bats test/
```

Run a single file or test:

```sh
bats test/unit.bats
bats --filter slugify test/
```

## Dependencies

| Tool       | Why                                            | Install                  |
| ---------- | ---------------------------------------------- | ------------------------ |
| `bats`     | test runner                                    | `brew install bats-core` |
| `jq`       | the engine's registry/config queries           | `brew install jq`        |
| `yq`       | YAML→JSON config parsing (`config.bats` only)  | `brew install yq`        |

If `yq` is missing, the `config.bats` tests **skip** with a clear message rather
than failing — everything else still runs. `bats` and `jq` are hard requirements.

## How the tests reach the functions

boxwood's `ws` entry point ends with a **main-guard**:

```sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in ... esac
fi
```

So the script can be **sourced** to define every function (and transitively
source `lib/colors.sh`, `lib/config.sh`, `lib/docker.sh`) **without** dispatching
a command. Each test's `setup()` calls `load_ws` (see `test/helper.bash`), which:

1. points `WS_HOME` at a fresh `mktemp -d` (so `REGISTRY`/`SESSIONS_DIR` are isolated per test), then
2. `source`s the `ws` script.

`REGISTRY` is then seeded per-test with `jq`/heredocs, and `CONFIG_JSON` /
`CONFIG` are overridden in-test where a function reads them.

Docker-backed functions (`compose_status`, `detect_session_state`,
`project_has_volumes`, …) are tested against a **PATH shim**: `stub_docker`
drops a fake `docker` executable on `PATH` whose canned `ps` / `volume ls`
output is controlled by env vars (`DOCKER_RUNNING`, `DOCKER_ANY`,
`DOCKER_VOLUMES`). No Docker daemon is required.

## Layout

| File           | Covers                                                                        |
| -------------- | ----------------------------------------------------------------------------- |
| `helper.bash`  | shared `load_ws`, `stub_docker`, `require_yq` helpers                         |
| `unit.bats`    | `slugify`, `registry_add/end/prune`, `next_port`, `find_session_by_cwd`, `generate_compose`, `confirm` (incl. `WS_ASSUME_YES`) |
| `docker.bats`  | `compose_status`, `detect_session_state`, `project_has_volumes`, `compose_project_name`, `compose_status_display` |
| `config.bats`  | `load_config`, `cfg`/`cfg_default`, `has_db`, `load_user_config`, `ucfg`/`ucfg_default`, `resolve_assistant_command` |
| `worktree.bats`| `resolve_base_ref`, `ensure_worktree` — git-worktree provisioning against **real throwaway repos** (detached-HEAD recovery, orphaned dir, branch checked out elsewhere, remoteless Base ref) |

## What is intentionally NOT unit-tested, and why

These functions are dominated by side effects (process exec, real `git`/`tmux`/
`docker` orchestration) and have little pure logic to assert in isolation. They
are better covered by integration tests against real tooling — and the **Tier-2
smoke harness** (`test/smoke.sh`) does exactly that end-to-end:

- **`cmd_attach`, `cmd_end`, `cmd_rebuild`, `cmd_exec`, `cmd_db_restore`,
  `cmd_list`** — top-level command flows. They wire together `git worktree`,
  `docker compose`, `gh`, the registry, and `tmux`, and most branches `exit`.
  Their pure pieces (slugify, registry, port allocation, state detection) are
  unit-tested individually above; the orchestration itself is covered by
  `test/smoke.sh`, which drives `attach --new/--branch/--pr`, `rebuild`, `list`,
  `exec`, `db-restore`, and `end` against real fixtures and containers.
  Specifically, `attach --pr` (its `gh pr view … | jq -r '.headRefName'` branch
  resolution, via a PATH-shimmed `gh`) and `db-restore` (re-running the repo's
  `restore_command` in the live app container, verified by a durable run counter)
  are exercised there — not as Tier-1 units, which would have to stub the entire
  orchestration. `cmd_init` is scaffold-only and remains uncovered by either tier.
  **Note:** the git-worktree provisioning that used to live inline in `cmd_attach`
  (Base-ref resolution + the detached-HEAD / orphan / stale-worktree recovery state
  machine) was extracted into `resolve_base_ref` / `ensure_worktree` and is now
  unit-tested directly in `worktree.bats` against real throwaway repos — so those
  edge cases no longer depend on the Docker smoke run to be exercised.
- **`launch_tmux`** — `exec`s into `tmux`; the only unit-testable behavior is the
  early `WS_NO_ATTACH` short-circuit. The rest spawns panes and replaces the
  process, so it cannot be meaningfully asserted in a sourced shell.
- **`setup_worktree`** — writes `.env`, a session-context file, and git excludes
  into a real worktree, and calls `git rev-parse --git-dir`. It needs a real git
  worktree to exercise, so it belongs in integration tests rather than a Tier-1
  unit.
- **`compose_up` / `compose_down`** — run `docker compose up --wait` / `down -v`
  against a live daemon; they have no pure logic worth stubbing end-to-end.
- **`load_repo_context` / `require_config`** — derive `REPO_ROOT`/`REPO` from
  `git rev-parse --git-common-dir`. Tested transitively (the accessors they feed
  are covered); a focused test would just be re-asserting `git`'s behavior.

`confirm` is covered for the `WS_ASSUME_YES`, `y`, and non-`y` paths.
`prompt_choice` is interactive-only (reads a free-form choice) and is left to
integration testing.
