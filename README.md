# boxwood

**Isolated, containerized dev sessions — one per git worktree — for any repo.**

Each session is a git worktree with its own Docker Compose stack (database,
services, ports), tmux layout, and an **Assistant** context (Claude Code by default)
— fully sealed off from your other work and from `main`. Point it at a branch or PR
and `boxwood` builds the environment; close it and everything tears down cleanly.

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
  git worktree → per-session Docker stack → host port → tmux → Assistant.
- Worktrees live under `~/.ws/sessions/<repo>/<branch>/` — real git checkouts, so your
  IDE sees full history and diffs against `main`.
- One `~/.ws/registry.json` tracks sessions across **all** repos.
- Each session is its own Docker Compose project (`ws-<repo>-<branch>`) with isolated
  volumes, so databases and dependency caches never bleed between branches.

---

## Install

**Prerequisites (macOS):** Docker ([OrbStack](https://orbstack.dev)), `git`, `jq`,
`yq`, and `tmux` are **required**. `gh` is optional (only `ws attach --pr` uses it);
[Claude Code](https://claude.com/claude-code) is optional (only the Assistant pane uses
it). The installer below provisions everything for you.

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Lance-Foley/boxwood/main/install.sh)"
```

The one-liner bootstraps Homebrew if it isn't already present, installs the required
tools (`git`, `tmux`, `jq`, `yq`, `gh`) plus OrbStack, clones boxwood to `~/.boxwood`,
and symlinks `ws` onto your PATH. It then runs a short interactive tail for the steps
that can't be automated: launching OrbStack, `gh auth login`, and optionally installing
Claude Code. Those three — Docker, GitHub auth, and the Assistant — are the
irreducibly-interactive parts; everything else is hands-off.

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
│  editor .       │  Assistant      │
├─────────────────┼─────────────────┤
│  app logs       │  container shell│
└─────────────────┴─────────────────┘
```

The top-left pane runs your configured editor (defaults to `$EDITOR`, then `nvim`); the
top-right runs your configured Assistant (Claude Code by default, or a plain shell if you
skip it). If you set a GUI editor it also opens on the worktree. The app is live at
`http://localhost:<port>`, and the dev server runs inside the container (it self-heals on
restart). Editor and Assistant come from your [per-user config](#per-user-config-wsconfigyml),
not the repo's recipe.

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
```

The recipe describes the **stack** only — your editor and Assistant live in your
[per-user config](#per-user-config-wsconfigyml), never in the committed `.ws/`.

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

## Per-user config (`~/.ws/config.yml`)

The committed `.ws/` recipe describes the **stack**; `~/.ws/config.yml` describes the
**developer**. Your editor and Assistant follow you across every repo and are never
committed — change repos and your tools come with you.

```yaml
editor: nvim                       # in-tmux editor; defaults to $EDITOR, then nvim
gui_editor: ""                     # external GUI editor (e.g. "rubymine", "code");
                                   # defaults to none — nothing extra opens

assistant:
  command: claude                  # the Assistant in the top-right pane; defaults to
                                   # Claude. Set to "" to skip it (plain shell instead).
  skip_permissions: true           # launch Claude with --dangerously-skip-permissions
```

- **`editor`** — runs in the top-left tmux pane. Falls back to `$EDITOR`, then `nvim`.
- **`gui_editor`** — an external GUI editor opened on the worktree. Defaults to none;
  set it only if you want a desktop IDE alongside the tmux layout.
- **`assistant.command`** — the AI tool in the top-right pane. Defaults to Claude Code,
  but is fully skippable: leave it empty and the pane is just a shell.

This file is per-user preference, not machine state — boxwood doesn't write it for you,
and it has no bearing on what a teammate sees when they adopt the same repo's `.ws/`.

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

## Testing / Development

- `bats test/` — unit tests for the engine's pure logic.
- `test/smoke.sh` — a smoke-lifecycle check against an `alpine` image (full
  first-run → resume → restart → end cycle, no real stack).
- WescomApp is the one-shot real-world parity run — proof the de-Wescom'd engine still
  reproduces the original tool's behavior on a real Rails + Postgres repo.

---

## Design docs

- [`CONTEXT.md`](CONTEXT.md) — the ubiquitous language (Project, `.ws/`, Orchestrator, Session…).
- [`docs/adr/`](docs/adr) — architecture decisions.
- [`docs/superpowers/specs/2026-05-29-ws-generalization-design.md`](docs/superpowers/specs/2026-05-29-ws-generalization-design.md) — the generalization design.
