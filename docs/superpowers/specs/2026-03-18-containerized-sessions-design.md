# Containerized Development Sessions

**Date:** 2026-03-18
**Status:** Draft
**Replaces:** Native worktree + local PostgreSQL approach

## Problem

The current `ws` tool creates isolated dev sessions using git worktrees and local PostgreSQL clones. This breaks frequently due to:

- Fragile Rails config patching (puma.rb, database.yml, Procfile.dev, session cookies)
- macOS-specific PostgreSQL issues (SolidQueue fork crashes, connection blocking on template clones)
- Environment drift (.env files, git excludes, assume-unchanged flags getting out of sync)
- The existence of `ws fix` as a repair command is a symptom of systemic fragility

## Solution

Replace local PostgreSQL and native Rails processes with fully isolated Docker Compose stacks per session. Each session gets its own containerized Postgres + Rails + SolidQueue, with application code mounted from the host worktree.

**Runtime:** OrbStack (Docker-compatible macOS runtime). Chosen over Docker Desktop for faster VirtioFS volume mounts, lower resource usage, and better macOS integration. Uses the same `docker` / `docker compose` CLI commands.

## Architecture

### Golden Base Image

A Docker image built from the wescomapp main branch. Uses the official Ruby slim-bookworm image matching `.ruby-version`.

```dockerfile
# Skeleton — actual Dockerfile will be in wescom-session/Dockerfile
FROM ruby:3.x-slim-bookworm

RUN apt-get update && apt-get install -y \
    build-essential libpq-dev git curl \
    postgresql-client nodejs npm && \
    npm install -g yarn

WORKDIR /app

# Pre-install dependencies from main branch (baked into image)
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Entrypoint handles dependency drift and DB init
COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

**What's baked in:** Ruby, system deps, bundled gems, node modules, pg client tools.

**Not in the image:** Application code (mounted at runtime), database data (per-session), `.env` / secrets (read from mount).

**Rebuild:** Manual via `ws rebuild`. Pulls latest main, copies its Gemfile.lock + package.json, rebuilds, tags as `wescomapp-dev:latest`.

**Dependency drift:** The entrypoint runs `bundle check || bundle install` and `yarn check --integrity || yarn install` on start. To avoid slow native gem compilation on branches that add gems, a named volume caches the bundle path (see Compose Template below).

### Container Entrypoint

```bash
#!/bin/bash
# docker-entrypoint.sh — runs inside the app container on every start

set -e

# Handle dependency drift from branches with new gems/packages
bundle check || bundle install
yarn check --integrity 2>/dev/null || yarn install

# Database initialization (only on first run)
# Marker file in the pgdata volume tracks whether init has run
if [ "$DB_INIT" = "true" ]; then
  echo "Waiting for PostgreSQL..."
  until pg_isready -h db -U postgres -q; do sleep 1; done

  echo "Restoring latest.dump..."
  pg_restore --no-owner --no-acl -h db -U postgres -d wescomapp /dumps/latest.dump || true

  echo "Running migrations..."
  bundle exec rails db:migrate

  echo "Resetting dev passwords..."
  bundle exec rake update_encrypted_passwords

  echo "Database ready."
fi

exec "$@"
```

- `DB_INIT=true` is set by `ws attach` only on first run (see Session Lifecycle below)
- `pg_isready` loop waits for Postgres to accept connections
- `pg_restore` runs from the app container using pg client tools against the `db` service hostname
- `|| true` on pg_restore because it returns non-zero on warnings even when restore succeeds
- `latest.dump` is bind-mounted from the host (see Compose Template)

### Compose Template

```yaml
# Template — ws attach generates this per session with correct values
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: wescomapp
      POSTGRES_HOST_AUTH_METHOD: trust
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      timeout: 5s
      retries: 10

  app:
    image: wescomapp-dev:latest
    environment:
      DATABASE_URL: postgres://postgres@db/wescomapp
      SOLID_QUEUE_IN_PUMA: "false"
      PORT: "3000"
      DB_INIT: "${DB_INIT:-false}"
    ports:
      - "${HOST_PORT}:3000"
    volumes:
      - ${WORKTREE_PATH}:/app
      - ${WESCOM_APP_PATH}/latest.dump:/dumps/latest.dump:ro
      - bundle_cache:/usr/local/bundle
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - ${WORKTREE_PATH}/.env

  worker:
    image: wescomapp-dev:latest
    command: bundle exec rails solid_queue:start
    environment:
      DATABASE_URL: postgres://postgres@db/wescomapp
      SOLID_QUEUE_IN_PUMA: "false"
    volumes:
      - ${WORKTREE_PATH}:/app
      - bundle_cache:/usr/local/bundle
    depends_on:
      app:
        condition: service_started
      db:
        condition: service_healthy
    env_file:
      - ${WORKTREE_PATH}/.env
    restart: on-failure:3

volumes:
  pgdata:
  bundle_cache:
```

**Key details:**
- SolidQueue runs as a **separate `worker` container** (same image, different command). Avoids process supervisor complexity, gets independent restart/logs. The worker `depends_on` the `app` service so it starts after the app (which handles DB init). On first run, the worker may start before DB init completes — `restart: on-failure:3` handles this by retrying until the database is ready.
- `bundle_cache` named volume persists installed gems across container restarts, so `bundle install` for drift gems only runs once.
- `latest.dump` is bind-mounted read-only from the host at `/dumps/latest.dump`.
- `DB_INIT` is passed as an env var; `ws attach` sets it to `true` on first run only.
- `depends_on` with `service_healthy` ensures Postgres is accepting connections before Rails starts.
- The `app` container's `env_file` reads the worktree `.env` for API keys, AWS creds, etc. Compose `environment` entries override any conflicts (DATABASE_URL, PORT, SOLID_QUEUE_IN_PUMA).
- All containers use a single database named `wescomapp` — isolation comes from the container, not the database name.

### Port Allocation

Pool-based, range `3001–3010`. Port 3000 is reserved for the main repo (non-containerized). `ws` picks the next available port from the pool and writes it into the compose file's `HOST_PORT` variable.

### File / Data Flow

```
Host (macOS)                              Container (Linux)
──────────────                            ──────────────────
$WESCOM_APP_PATH/.env              ──►    Copied to worktree by ws attach
~/code/wescom-sessions/<branch>/   ──►    Mounted at /app (read-write)
$WESCOM_APP_PATH/latest.dump       ──►    Bind-mounted at /dumps/latest.dump (read-only)
RubyMine edits files               ──►    Rails auto-reloads on file change
Browser → localhost:300X           ──►    Mapped to container port 3000
```

## Session Lifecycle

### First run detection

`ws attach` determines "first run" vs "resume" by checking whether the Docker Compose project exists and has running containers:

```bash
docker compose -p ws-<branch> ps --status running --format json
```

- **No project / no running containers + no pgdata volume:** First run. Set `DB_INIT=true`, start everything.
- **Running containers:** Resume. Attach tmux to existing session.
- **Stopped containers (no running, but volume exists):** `docker compose up -d` without `DB_INIT`. Database volume still has data.

The pgdata named volume is the source of truth for database state. If the volume exists, the database is initialized. If it doesn't (removed during `ws end`), `DB_INIT=true` triggers a fresh restore.

## ws Commands

### `ws rebuild`
Rebuilds the golden base image from latest main:
1. `git fetch origin && git checkout origin/main` in a temp copy of wescomapp (or use main worktree)
2. Copy `Gemfile`, `Gemfile.lock`, `package.json`, `yarn.lock`, `.ruby-version` into build context
3. `docker build -t wescomapp-dev:latest .`
4. Print image size and tag

### `ws attach --branch <name>` / `--pr <N>` / `--new "description"`
Creates or resumes a session:
1. Check that `wescomapp-dev:latest` image exists (error with "run `ws rebuild` first" if not)
2. Resolve branch (same logic as today — PR lookup via `gh`, new branch creation, etc.)
3. Create/reuse git worktree in `~/code/wescom-sessions/<branch>/`
4. Copy `.env` from main repo to worktree (if not already present)
5. Generate `docker-compose.yml` in the worktree directory from template (substitute HOST_PORT, WORKTREE_PATH, WESCOM_APP_PATH). The compose project name is `ws-<slugified-branch>` (branch names are slugified: `/` → `-`, lowercased, matching Docker Compose's `[a-z0-9][a-z0-9_-]*` requirement).
6. Detect first run vs resume (see Session Lifecycle above)
7. `DB_INIT=true docker compose -p ws-<branch> up -d` (first run) or `docker compose -p ws-<branch> up -d` (resume)
8. Register in `~/.wescom-sessions.json`
9. Launch tmux session
10. Open RubyMine pointed at worktree

### `ws list`
Shows active sessions with branch, port, and container status.

Reads registry entries, then for each active session:
```bash
docker compose -p ws-<branch> ps --format "table {{.Service}}\t{{.State}}" 2>/dev/null
```
Displays: BRANCH | PORT | STATUS (running/stopped/no containers)

### `ws end [--branch <name>]`
Tears down a session:
1. Show git status (commits ahead of main, uncommitted files)
2. Prompt: push branch to origin?
3. `docker compose -p ws-<branch> down -v` (stops containers, removes pgdata + bundle_cache volumes)
4. Prompt: remove worktree?
5. Mark registry entry as "ended"
6. Kill tmux session

### `ws exec <command>` (new convenience)
Runs a command inside the session's app container:
```bash
ws exec rails console
ws exec rails db:migrate
```
Detects current session by matching `$PWD` against registry `.path` entries, then runs:
```bash
docker compose -p ws-<branch> exec app <command>
```

## tmux Layout

```
┌─────────────────┬─────────────────┐
│  App + Worker   │  Claude Code    │
│  logs           │  claude --skip… │
│  (docker compose│  (runs on host) │
│   logs -f)      │                 │
├─────────────────┤                 │
│  In-container   │                 │
│  shell (bash)   │                 │
│  via exec       │                 │
└─────────────────┴─────────────────┘
```

- **Top-left:** `docker compose -p ws-<branch> logs -f app worker` — Puma + SolidQueue output (both services, labeled)
- **Bottom-left:** `docker compose -p ws-<branch> exec app bash` — interactive shell for rails console, migrations, etc.
- **Right:** Claude Code on the host, pointed at the worktree directory

## RubyMine

Opens the worktree directory on the host. No change from today. RubyMine is unaware of containers — it edits local files, which are instantly visible inside the container via the volume mount.

## Session Memory and Claude Code Context

Preserved from the current ws tool:
- `.session/memory/` directory in the worktree for Claude Code session context
- `CLAUDE.md` in the worktree with session-specific instructions (branch, port, PR link)
- Both are created by `ws attach` during setup, same as today

## What This Eliminates

- Local PostgreSQL dependency (no brew services, no template cloning, no connection fights)
- All Rails config patching (puma.rb, database.yml, session cookies, Procfile.dev)
- macOS SolidQueue fork crash workarounds (SOLID_QUEUE_IN_PUMA, WEB_CONCURRENCY are still set but the Linux container doesn't have the underlying issue)
- `ws fix` command (nothing to drift out of sync)
- `git update-index --assume-unchanged` hacks
- `.env` override appending (compose `environment` sets the few overrides, rest from mounted .env)
- `lib/database.sh` — all functions (`db_clone`, `db_drop`, `db_exists`, `db_list_session_dbs`) are replaced by Docker volume/container lifecycle. This file is removed.

## What This Preserves

- Git worktrees in `~/code/wescom-sessions/`
- Session registry in `~/.wescom-sessions.json`
- Port allocation from a pool
- `ws attach` / `ws list` / `ws end` UX
- RubyMine + Claude Code + tmux workflow
- `.session/memory/` and `CLAUDE.md` per-session context

## What's New

- OrbStack installed on macOS (Docker runtime, VirtioFS mounts)
- `Dockerfile` + `docker-entrypoint.sh` in wescom-session repo
- `docker-compose.template.yml` in wescom-session repo
- `ws rebuild` command
- `ws exec` convenience command
- SolidQueue as separate `worker` container (cleaner than in-process)

## Migration from Current Setup

Existing sessions created by the old `ws` tool will not be compatible with the new containerized approach. Migration path:

1. `ws end` all active sessions using the current tool (push branches first)
2. Drop orphaned session databases: `ws list` will show them
3. Install OrbStack, run `ws rebuild` to create the base image
4. Resume work with `ws attach --branch <name>` — new containerized sessions

The registry format remains the same, but old entries with `status: "ended"` are inert. A version field will be added to new entries to distinguish containerized sessions from legacy ones.

## Prerequisites

- OrbStack installed (`brew install orbstack`)
- wescomapp repo at `$WESCOM_APP_PATH` (defaults to `~/code/WescomApp`) with valid `.env` and `latest.dump`
- `gh` CLI authenticated (for PR branch resolution)
- `wescomapp-dev:latest` image built (via `ws rebuild`)
