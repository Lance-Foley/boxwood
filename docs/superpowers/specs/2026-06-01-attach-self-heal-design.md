# `ws attach` self-heal — design

## Problem

`ws attach` can land on a session whose **app container is dead** while the worker
and db containers are still running. Two failures result:

1. **Misdetection.** `compose_status` (`lib/docker.sh:51`) returns `running` if *any*
   container is up (`head -1` on the running list). So a half-dead stack is reported
   as `running`, `detect_session_state` returns `resume`, and `cmd_attach` prints
   "Containers already running" and **skips `compose_up`** — never repairing the app.

2. **Lockout on first-run failure.** When `compose_up`'s first-run recreation fails
   (`lib/docker.sh:133`), it `exit 1`s. Because `compose_up` runs (`ws:513`) *before*
   `launch_tmux` (`ws:531`), the script dies before any tmux session is created, so
   there is nothing for a later `ws attach` to attach to.

The user requirement: re-running `ws attach` on a broken session must **figure it out
and fix it** — restart, or destroy-and-reinitialize the containers/DB — while the
**git branch and worktree are always preserved**.

## Decisions (from brainstorming)

- **Repair strategy:** escalating. First a cheap restart (recreate the app container,
  keep the DB volume). Only if it still won't come up healthy, drop the DB volume and
  re-run first-run init. Branch/worktree untouched in every path.
- **Reinit consent:** automatic, with a loud notice. No interactive prompt.
  `WS_ASSUME_YES` stays honored for scripted runs.
- **If even reinit can't heal:** error out with logs and a non-zero exit. Do **not**
  attach tmux into a dead stack.

## Approach

Health-aware state detection + an escalation wrapper in `lib/docker.sh`, reusing the
existing (already-tested) `service_healthy` / `service_health_ok` helpers. Keeps `ws`
thin and each piece independently unit-testable with the existing docker stub.

### 1. Detection — don't call a half-dead stack `resume`

`detect_session_state` gains an optional `app_service` argument:

```
detect_session_state(project, app_service=""):
  status = compose_status(project)
  case status:
    running:
      if app_service != "" and not service_healthy(project, app_service):
        echo "restart"        # containers up but app broken → repair
      else:
        echo "resume"
    stopped: echo "restart"
    none:    project_has_volumes ? "restart" : "first_run"
```

With no `app_service` (other callers, existing tests) the behavior is unchanged.

### 2. Startup with escalation — new `start_session` in `lib/docker.sh`

```
start_session(project, worktree, port, state, app_service):
  if compose_up(project, worktree, port, state): return 0
  # restart/first_run failed — escalate once to a clean reinit
  if state != "first_run" and project_has_volumes(project):
    warn "App did not come up healthy — reinitializing DB volume (branch & worktree untouched)."
    compose_down(project, worktree)          # drops the DB volume only
    compose_up(project, worktree, port, "first_run")
    return $?
  return 1
```

`compose_up`'s two failure `exit 1`s (`lib/docker.sh:124`, `:137`) become `return 1`
so the wrapper can catch them. `cmd_attach` is the only caller path and now goes
through `start_session`, so nothing else relies on the old exit behavior.

### 3. `cmd_attach` start block (`ws:500-514`)

- `state=$(detect_session_state "$project" "$app_service")` — resolve `app_service`
  from `cfg_default '.compose.app_service' 'app'` (same default `compose_up` uses).
- `--reset` still forces a clean `first_run` up front (explicit consent, unchanged).
- **Remove** the interactive `confirm "Database exists from a previous run. Drop…?"`
  prompt — the automatic escalation supersedes it.
- `resume` → "Containers already running"; otherwise:
  `start_session … || { error "Could not bring the session up healthy — see logs above."; exit 1; }`
- The hard-failure `exit 1` happens before `launch_tmux` (the "error out, no tmux"
  decision).

### Outcomes

| Situation | Behavior |
|---|---|
| App died, DB fine | silent `restart`, attach |
| DB never initialized / restart can't heal | auto reinit with loud notice, attach |
| Genuinely unfixable | logs + non-zero exit, no tmux |
| Branch / worktree | untouched in every path |

## Testing (`test/docker.bats`)

Extend the docker stub (`test/helper.bash`) so a per-service `ps <service>` can report
unhealthy (e.g. `DOCKER_APP_UNHEALTHY=1` → app service line has
`"State":"running","Health":"unhealthy"`, other services healthy).

- `detect_session_state`, running + app unhealthy + `app_service` → `restart`
- `detect_session_state`, running + app healthy + `app_service` → `resume`
- existing no-arg `detect_session_state` cases still pass (back-compat)
- `start_session`: first `compose_up` fails + volumes present → `compose_down` then
  `first_run` reinit invoked
- `start_session`: first `compose_up` fails + no volumes → returns 1, no reinit

## Out of scope

- The `ws attach <name>` bare-positional shorthand (separate ergonomic ask).
- The WescomApp SolidQueue/Puma boot crash itself (app-side, not boxwood).
