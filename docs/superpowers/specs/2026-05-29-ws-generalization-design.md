# ws Generalization: Repo-Agnostic Session Orchestrator

**Date:** 2026-05-29
**Status:** Implemented (2026-05-29)
**Goal:** Turn `ws` from a WescomApp-specific tool into a generic, repo-agnostic
orchestrator for isolated containerized dev sessions. Any repo can adopt it by
committing a `.ws/` directory; WescomApp becomes the first such config and behaves
exactly as it does today.

## Problem

The current `ws` engine — git worktree per branch, per-session Docker Compose stack,
port pool, registry, tmux layout, Claude Code context, lifecycle states — is already
generic. But the build/DB/serve steps are hardcoded to WescomApp + Rails:

- `latest.dump` + `pg_restore` into a hardcoded `wescomapp` database
- `rake update_encrypted_passwords` (a bespoke WescomApp task)
- Rails toolchain assumptions (bundle, yarn, foreman/Procfile.dev, SolidQueue, Ruby 3.4.4)
- `WESCOM_APP_PATH`, golden image baked from `main`'s lockfiles
- A DB-specific readiness signal (`ws` greps app logs for the literal `"Database ready."`)

## Solution

`ws` becomes a pure orchestrator. Each repo declares its own session recipe in a
committed `.ws/` directory; `ws` knows nothing about Rails or any specific stack.

### Repo-owned `.ws/`

Each repo commits:

```
.ws/
├── config.yml                    # the recipe ws reads (thin — see schema)
├── Dockerfile                    # golden base image for this repo
├── docker-compose.template.yml   # per-session stack (services, volumes, healthchecks)
├── docker-entrypoint.sh          # dependency-drift reconcile + first-run hook
└── db-init.sh                    # optional: DB setup (repos without a DB omit it)
```

`ws init` scaffolds a Rails+Postgres starter set (the current WescomApp assets,
de-Wescom'd) that a repo then customizes.

### Config schema (`.ws/config.yml`)

Deliberately thin — the compose template and Dockerfile carry runtime detail. Config
holds only what the orchestrator needs:

```yaml
version: 1
main_branch: main

image:
  name: <repo>-dev:latest
  dockerfile: .ws/Dockerfile
  build_context_from_main: [Gemfile, Gemfile.lock, package.json, yarn.lock]

compose:
  template: .ws/docker-compose.template.yml
  app_service: app          # which service ws wires logs/exec/port to
  ready: healthcheck        # ws uses `compose up -d --wait`; no log-string coupling

ports: { range: [3000, 3005] }

secrets_file: .env          # copied from the main checkout into each worktree

db:                         # omit entirely for repos with no database
  restore_command: /usr/local/bin/db-init.sh   # what `ws db-restore` runs

claude:
  skip_permissions: true    # passes --dangerously-skip-permissions
```

### Layout (`~/.ws/` home)

- **Repo identity:** `git rev-parse --show-toplevel` from `$PWD`. The repo's basename
  is its key.
- **Worktrees:** `~/.ws/sessions/<repo>/<branch>/`. Keeps `~/code` uncluttered.
- **Registry:** single `~/.ws/registry.json`, each entry tagged with `repo`. `ws list`
  shows the current repo by default; `ws list --all` shows every repo.
- `WESCOM_APP_PATH` is removed; the "main checkout" is the detected repo root.

### Readiness detection

`ws` uses the app service's compose **healthcheck** via `docker compose up -d --wait`
instead of grepping logs for `"Database ready."`. Generic across DB and non-DB repos;
the healthcheck definition lives in the repo's compose template.

## Command flow changes

- `ws init` — **new.** Scaffold `.ws/` in the current repo with a starter config + assets.
- `ws rebuild` — reads `image.*` from config; copies `build_context_from_main` files from
  `main_branch` into the build context; builds `image.name` from `.ws/Dockerfile`.
- `ws attach` — detect repo → read `.ws/config.yml` → worktree under
  `~/.ws/sessions/<repo>/<branch>/` → generate compose from the repo's template →
  `up -d --wait` → register (with `repo`) → tmux → Claude.
- `ws list` — current repo by default, `--all` for everything.
- `ws end` / `ws exec` / `ws db-restore` — unchanged semantics; `db-restore` runs
  `db.restore_command`; skipped/no-op when the config has no `db` block.

## What stays the same

- The session engine: worktrees, per-session compose projects (`ws-<repo>-<branch>`),
  per-session volumes, port pool, registry, tmux layout, lifecycle states, Claude context.
- For WescomApp specifically: behavior is identical once its `.ws/` is committed.

## Migration

1. Move the current `Dockerfile`, `docker-compose.template.yml`, `docker-entrypoint.sh`,
   `db-init.sh` into WescomApp's `.ws/` and add `.ws/config.yml`.
2. De-Wescom the `ws` script (drop `WESCOM_APP_PATH`, hardcoded `wescomapp`, the log-grep).
3. Migrate the registry to `~/.ws/registry.json` with a `repo` field (or start fresh).

## Name

The CLI command stays `ws` (reinterpreted as "work session" / "worktree session").
The project/repo is renamed accordingly (`ws` / `worksession`), shedding the Wescom meaning.

## Open questions / deferred

Several of the original open questions are now decided (see
[`docs/adr/0003`](../../adr/0003-agnostic-engine-per-user-config.md)):

- **Runtime dependency — decided.** The engine carries no language runtime: config is
  parsed with `yq -o=json`, not Ruby. Required deps are `git docker tmux jq yq`; Ruby
  drops off entirely.
- **Per-user config layer — decided.** Editor and Assistant are no longer hardcoded
  (`nvim`/RubyMine/`claude`) and no longer committed in the per-repo recipe. They live
  in a per-user `~/.ws/config.yml` (`editor`, `gui_editor`, `assistant.command`/
  `skip_permissions`) that follows the developer across every repo. The committed `.ws/`
  recipe describes the *stack*; the per-user config describes the *developer*.
- **Installer — decided (Mac-only).** A remote one-liner
  (`bash -c "$(curl -fsSL …/install.sh)"`) bootstraps Homebrew, installs the dep set +
  OrbStack, clones to `~/.boxwood`, symlinks `ws`, and runs a short interactive tail.
  The *engine* stays Linux-clean (POSIX commands) so a Linux installer is additive
  later, but only the macOS installer ships now.
- **`gh` / GitHub coupling — decided.** `gh` is optional (only `--pr` needs it); the
  one-time `gh auth login` moves into the installer. `cmd_attach`'s `git fetch origin` /
  `origin/$main_branch` degrades gracefully for remote-less or non-`origin` repos.

Genuinely remaining:

- **Linux installer.** Deferred, not blocked — the engine is already Linux-clean, so this
  is additive (brew → apt/dnf, `open` → `xdg-open`) whenever a Linux user appears.
- **`ws init` stack auto-detection.** Starter content ships as the Rails+Postgres set,
  but how much `init` infers from the repo (Gemfile present → Rails starter, etc.) is
  still TBD. Truly different stacks (no DB, non-Ruby, multiple app services) are
  *enabled* by the design but not yet exercised.
