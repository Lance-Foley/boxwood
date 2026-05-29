# boxwood

**Isolated, containerized dev sessions — one per git worktree — for any repo.**

Each session is a git worktree with its own Docker Compose stack (database,
services, ports), tmux layout, and Claude Code context — fully sealed off from your
other work and from `main`. Point it at a branch or PR and `boxwood` builds the
environment; close it and everything tears down cleanly.

A repo opts in by committing a `.ws/` recipe; `boxwood` itself is stack-agnostic.
The CLI is `ws`.

> *Boxwood* is a hardy evergreen hedge — **box** for the container each session runs
> in, **wood** for the stand of worktrees growing from one trunk.

---

## How it works

```
your-repo/                         ~/.ws/
├── .ws/                           ├── registry.json          # all sessions, every repo
│   ├── config.yml   ── recipe ──▶ └── sessions/
│   ├── Dockerfile                     └── your-repo/
│   ├── docker-compose.template.yml        ├── add-search/    # a worktree + its stack
│   ├── docker-entrypoint.sh               └── fix-login/     # another, fully isolated
│   └── db-init.sh
└── … your app …
```

- `ws` finds the repo you're in (via git), reads its `.ws/config.yml`, and orchestrates:
  git worktree → per-session Docker stack → host port → tmux → Claude Code.
- Worktrees live under `~/.ws/sessions/<repo>/<branch>/` — real git checkouts, so your
  IDE sees full history and diffs against `main`.
- One `~/.ws/registry.json` tracks sessions across **all** repos.
- Each session is its own Docker Compose project (`ws-<repo>-<branch>`) with isolated
  volumes, so databases and dependency caches never bleed between branches.

---

## Install

**Prerequisites:** Docker ([OrbStack](https://orbstack.dev) recommended on macOS),
`git`, `jq`, `ruby` (for parsing `.ws/config.yml` — preinstalled on macOS), `tmux`,
and the [Claude Code](https://claude.com/claude-code) CLI. `gh` is optional (only for
`ws attach --pr`).

```sh
git clone git@github.com:Lance-Foley/boxwood.git
cd boxwood
./install.sh        # checks deps, symlinks `ws` onto your PATH
```

`install.sh` symlinks `ws` into `/usr/local/bin` (or `~/.local/bin`).

---

## Quick start

In any repo you want isolated sessions for:

```sh
cd ~/code/my-app

ws init                          # scaffold .ws/ (rails-postgres starter by default)
$EDITOR .ws/config.yml           # tune it for your app (see reference below)
git add .ws && git commit -m "Add boxwood session recipe"

ws rebuild                       # build this repo's base image (once, and after dep bumps)

ws attach --new "Add search"     # create a branch + session and drop into tmux
```

You land in a tmux window:

```
┌─────────────────┬─────────────────┐
│  nvim .         │  Claude Code    │
├─────────────────┼─────────────────┤
│  app logs       │  container shell│
└─────────────────┴─────────────────┘
```

RubyMine opens on the worktree, the app is live at `http://localhost:<port>`, and the
dev server runs inside the container (it self-heals on restart).

---

## Commands

| Command | What it does |
|---------|--------------|
| `ws init [--template <name>]` | Scaffold `.ws/` in the current repo (default template: `rails-postgres`). |
| `ws attach --new "description"` | Create a new branch off `main_branch` + a fresh session. |
| `ws attach --branch <name>` | Session for an existing branch (resumes if it already exists). |
| `ws attach --pr <number>` | Resolve the PR's branch via `gh` and start/resume its session. |
| `ws list [--all]` | Active sessions in the current repo, or `--all` across every repo. |
| `ws end [--branch <name>]` | Push (optional), tear down containers + volumes, remove the worktree. |
| `ws rebuild` | Build/refresh this repo's golden base image from `main`. |
| `ws exec <command>` | Run a command in the session's app container (`ws exec rails console`). |
| `ws db-restore [--branch <name>]` | Re-run the repo's DB setup against a running session. |

`attach` is the single entry point: it creates a session the first time and resumes it
(reattaching tmux, restarting stopped containers) every time after.

---

## The `.ws/config.yml` recipe

`ws` only reads what it needs to orchestrate; the Dockerfile and compose template carry
the runtime detail.

```yaml
version: 1
main_branch: main                  # base for --new; diff/compare base

image:
  name: my-app-dev:latest          # tag for THIS repo's base image
  dockerfile: .ws/Dockerfile
  build_context_from_main: [Gemfile, Gemfile.lock, package.json, yarn.lock]

compose:
  template: .ws/docker-compose.template.yml
  app_service: app                 # service ws wires logs / exec / port to
  ready: healthcheck               # ws waits on the app healthcheck (compose up --wait)

ports:
  range: [3000, 3005]              # host port pool; one session per port

secrets_file: .env                 # copied from the main checkout into each worktree

db:                                # delete this block for an app with no database
  restore_command: /usr/local/bin/db-init.sh

claude:
  skip_permissions: true           # launch Claude with --dangerously-skip-permissions
```

### Compose template substitutions

`ws` generates each session's `docker-compose.yml` from your template, substituting:

| Token | Value |
|-------|-------|
| `__HOST_PORT__` | the session's assigned host port |
| `__WORKTREE_PATH__` | the worktree dir (mount your code from here) |
| `__REPO_ROOT__` | the main checkout (e.g. to bind-mount a `latest.dump`) |
| `__DB_INIT__` | `true` on first run, `false` afterwards |

The starter template runs the dev server as the **app container's own command** so it
survives restarts, runs a separate **worker** container for background jobs (which skips
dependency reconciliation via `WS_ROLE=worker`), and gates the worker on an app
**healthcheck** that flips green once first-run init finishes. See
[`docs/adr/0001`](docs/adr/0001-app-container-owns-dev-server.md).

### DB from a production dump

The `rails-postgres` starter's `db-init.sh` uses `rails db:prepare`. To bootstrap from a
production dump instead, bind-mount the dump in the compose template:

```yaml
    volumes:
      - __REPO_ROOT__/latest.dump:/dumps/latest.dump:ro
```

and replace `db-init.sh`'s body with a `pg_restore` flow (drop → create → restore →
migrate). `db-init.sh` is the single source of truth — both first-run init and
`ws db-restore` call it.

---

## Lifecycle states

`ws attach` figures out what to do from the containers + volumes:

- **first run** — no containers, no volumes → build the stack, run first-run init (`DB_INIT=true`).
- **resume** — containers already running → just reattach tmux.
- **restart** — containers stopped but volumes exist → start them; data is preserved.

`ws end` removes volumes, so the next `attach` is a clean first run.

---

## Troubleshooting

- **"Base image not found"** — run `ws rebuild` in the repo first.
- **"All session ports are in use"** — `ws end` a session, or widen `ports.range`.
- **Session won't become healthy** — `docker compose -p ws-<repo>-<branch> logs` to see why
  the app healthcheck is failing.
- **Stale worktree blocking a branch** — `ws` offers to remove it; otherwise
  `git worktree prune` in the main checkout.

---

## Design docs

- [`CONTEXT.md`](CONTEXT.md) — the ubiquitous language (Project, `.ws/`, Orchestrator, Session…).
- [`docs/adr/`](docs/adr) — architecture decisions.
- [`docs/superpowers/specs/2026-05-29-ws-generalization-design.md`](docs/superpowers/specs/2026-05-29-ws-generalization-design.md) — the generalization design.
