# ws — Work Session Orchestrator

`ws` creates isolated, containerized development sessions for **any** repo. Each
session is a git worktree + a per-session Docker Compose stack + a tmux layout +
Claude Code context. A repo opts in by committing a `.ws/` directory describing its
session recipe; `ws` itself is stack-agnostic. WescomApp is the first such repo —
its `.ws/` produces a Rails app + Postgres + SolidQueue worker, the tool's original
behavior. See `docs/superpowers/specs/2026-05-29-ws-generalization-design.md`.

## Language

**Project**:
A repo that has adopted `ws`, identified by its git toplevel and basename. Declares
its session recipe in a committed `.ws/` directory. `ws` detects the current project
from `$PWD`.
_Avoid_: app, target (use Project)

**`.ws/`**:
The committed per-project recipe: `config.yml` + `Dockerfile` + compose template +
entrypoint + optional `db-init.sh`. Owned by the Project, read by the orchestrator.

**Orchestrator**:
`ws` itself — the stack-agnostic engine (worktrees, ports, registry, tmux, lifecycle,
Claude context). Knows nothing about Rails or any specific stack.

**Session**:
One unit of work within a Project — a git worktree under
`~/.ws/sessions/<repo>/<branch>/`, its dedicated Compose project, volumes, host port,
and tmux session. Identified by branch name.
_Avoid_: environment, instance, workspace

**Registry**:
`~/.ws/registry.json` — the record of sessions across all Projects and their metadata
(repo, branch, port, path, pr, started, status). Source of truth for `ws list` and
port allocation; `ws list` filters to the current Project by default.
_Avoid_: session file, database (the registry is not the DB)

**Golden base image**:
A Project's dev base image (e.g. `wescomapp-dev:latest`), built by `ws rebuild` from the
Project's `.ws/Dockerfile` using lockfiles pulled from its `main_branch`. Dependencies
are baked in; app code, DB data, and secrets are not.
_Avoid_: dev image, base container

**Dependency drift**:
When a branch adds gems/packages not in the golden image. Reconciled by the container
entrypoint on start; installs land in the session's own `bundle_cache` volume.
_Avoid_: dependency mismatch

**DB init**:
The first-run database setup: drop → create → `pg_restore` from `latest.dump` → migrate
→ reset dev passwords → verify table count. `ws db-restore` re-runs it on demand.
_Avoid_: seeding, db setup

**Lifecycle state**:
Derived by `detect_session_state` from container/volume presence:
**first_run** (no containers, no volume → `DB_INIT=true`), **resume** (containers running
→ reattach tmux), **restart** (volume exists, containers stopped → start without re-init).

## Relationships

- A **Session** has exactly one Compose project, one pgdata volume, and one **lifecycle state** at a time.
- The pgdata **volume** — not the **Registry** — is the source of truth for whether **DB init** has run.
- **Golden base image** + **dependency drift** reconciliation together provide a Session's gems/modules.

## Example dialogue

> **Dev:** "When I `ws attach` a branch whose containers are stopped but the volume's still there, does it re-restore the dump?"
> **Lance:** "No — that's a **restart**, not a **first_run**. The pgdata volume still has the data, so `DB_INIT` stays false and **DB init** is skipped. You'd only get a fresh restore if the volume was gone, or if you explicitly run `ws db-restore`."

## Flagged ambiguities

- "database" was used to mean both the **Registry** and the Postgres DB — resolved: the Registry tracks sessions; the pgdata volume holds the database and is the source of truth for init state.
