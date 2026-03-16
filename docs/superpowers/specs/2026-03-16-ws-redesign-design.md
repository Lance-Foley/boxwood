# WS Redesign: Lean Session Manager for WescomApp

**Date:** 2026-03-16
**Status:** Draft
**Goal:** Drastically simplify the `ws` tool — 3 commands, ~200 lines, real git branches, proper RubyMine integration, Claude Code session memory.

---

## Problem Statement

The current `ws` tool (~850 lines across 6 files) has two core issues:

1. **Worktree location:** Sessions live in `.claude/worktrees/` inside the main repo. RubyMine doesn't treat these as proper git projects, so diffs against `main` are hard to see.
2. **Branch identity:** `ws attach --pr 123` creates a new worktree and branch instead of checking out the actual PR branch with its commit history. There's no real version control on the branches.

Secondary issues: Notion integration adds ~40% of the codebase for a feature that Claude Code can handle via MCP. Rails config patching (puma.rb, Procfile.dev, bin/dev) is fragile. Six commands is more surface area than needed.

## Design

### Command Interface

Three commands:

#### `ws attach` — single entry point for all sessions

```
ws attach --pr 123              # attach to existing PR
ws attach --branch feature-name # attach to existing branch
ws attach --new "Add search"    # create new branch + session
```

Behavior:
- `--pr`: resolves branch name via `gh pr view <N> --json headRefName` (requires `gh auth status` to pass)
- `--branch`: uses the branch name directly
- `--new`: slugifies the name (lowercase, hyphens, max 50 chars), creates branch off `main`
- No flags: error with usage help
- In all cases: if a worktree already exists for that branch, resume it (reattach tmux, open RubyMine). If not, create new worktree + DB + tmux.
- On resume with existing DB: prompt "Database exists. Reuse or fresh clone?"
- On resume with missing DB (worktree exists but DB was dropped): create fresh clone without prompting

#### `ws list` — show active sessions

```
ws list
```

Displays a table: branch, database, port, path, started date. Sources from session registry cross-referenced with `git worktree list`.

#### `ws end` — tear down session

```
ws end                    # end session detected from current directory
ws end --branch feature   # end specific session by branch name
```

Interactive prompts:
1. Push branch to origin?
2. Drop database?
3. Remove worktree?

Then kills the tmux session and marks the registry entry as ended.

**Current directory detection:** `ws end` (no flags) matches `$(pwd)` against registered worktree paths using a prefix match — so it works whether you're in the worktree root or a subdirectory like `app/models/`.

### Worktree & Git Strategy

**Worktree location:**
```
~/code/wescom-sessions/<branch-name>/
```

**Existing PRs/branches** (`--pr` or `--branch`):
```sh
git -C "$WESCOM_APP_PATH" fetch origin
git -C "$WESCOM_APP_PATH" worktree add "$SESSIONS_DIR/$dir_name" "origin/$branch"
```
- Checks out the real remote branch with full commit history
- Diffs against `main` work natively in RubyMine

**New features** (`--new`):
```sh
git -C "$WESCOM_APP_PATH" fetch origin
git -C "$WESCOM_APP_PATH" checkout main && git -C "$WESCOM_APP_PATH" pull --ff-only
git -C "$WESCOM_APP_PATH" worktree add -b "$slug" "$SESSIONS_DIR/$slug"
```
- Fetches latest `origin/main` before branching so the new branch is never stale
- Creates branch off `main`, real branch name from the start

**Directory naming for branches with slashes:**
Branches with slashes (e.g. `feature/search`) are slugified for the directory name: slashes become hyphens. E.g. `feature/search` → `~/code/wescom-sessions/feature-search/`. This avoids collisions (`feature/search` and `bugfix/search` become `feature-search` and `bugfix-search`) and avoids nested directories.

If the slugified directory name collides with an existing session for a different branch (e.g. branch `feature-search` exists alongside `feature/search`), error with a message identifying the conflict.

**Resume detection:**
- Before creating anything, check if `$SESSIONS_DIR/<branch-name>/` already exists
- If it does, skip worktree/DB creation, go straight to tmux + RubyMine

**RubyMine:**
```sh
open -a "RubyMine" "$worktree_path"
```
Since worktrees are proper git checkouts, RubyMine sees full git history, branch tracking, and diffs against `main` natively.

### Database Management

**Naming:**
```
wescomapp_dev_<branch_slug>
```
Branch slug: replace `-` and `/` with `_`. E.g. `add-user-search` -> `wescomapp_dev_add_user_search`.

**New session:**
```sh
# Terminate connections to source DB
psql -U "$PG_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_BASE_DB' AND pid <> pg_backend_pid();"
# Clone
createdb -U "$PG_USER" -T "$PG_BASE_DB" "$db_name"
```
Retry up to 3 times if connections interfere (keep existing retry logic).

**Resume:**
- Check if DB exists: `psql -U "$PG_USER" -lqt | grep -qw "$db_name"`
- Prompt: "Database `wescomapp_dev_X` exists. Reuse or fresh clone?"
- Fresh: drop then re-clone

**Teardown:**
- Prompt: "Drop database?"
- If yes: terminate connections, `dropdb`

**Environment:**
```sh
cp "$WESCOM_APP_PATH/.env" "$worktree_path/.env"
# Append overrides
cat >> "$worktree_path/.env" << EOF
DATABASE_URL=postgres://localhost/$db_name
PORT=$port
SOLID_QUEUE_IN_PUMA=false
WEB_CONCURRENCY=0
EOF
```

- `DATABASE_URL` and `PORT`: session isolation
- `SOLID_QUEUE_IN_PUMA=false`: prevents Solid Queue from running inside Puma (macOS fork crash)
- `WEB_CONCURRENCY=0`: disables Puma cluster mode (same macOS fork safety)

No patching of `puma.rb`, `Procfile.dev`, or `bin/dev`. Environment variables handle port binding and fork safety. If WescomApp's `puma.rb` has `plugin :solid_queue`, the `SOLID_QUEUE_IN_PUMA=false` env var prevents it from activating.

**Port assignment:**
- Scan active sessions in registry, find lowest unused port in 3000-3004 range
- Written to `.env` as `PORT=300X`
- If all 5 ports are in use: error with message "All session ports (3000-3004) are in use. Run `ws end` to free a session." Refuse to create the session.

### Session Memory & Claude Code Integration

**Directory structure inside each worktree:**
```
~/code/wescom-sessions/<branch>/
├── .session/
│   └── memory/            # Claude reads/writes session context here
└── ... (Rails app files)
```

**Claude Code context:**
Append a session-specific section to the existing `CLAUDE.md` in the worktree root (which comes from WescomApp's own `CLAUDE.md`). Since this modifies a tracked file, add `CLAUDE.md` to the worktree's local git exclude (`.git/info/exclude`) so it doesn't show as dirty in `git status` or RubyMine.

```sh
# After appending session context to CLAUDE.md:
echo "CLAUDE.md" >> "$worktree_path/.git/info/exclude"
```

Appended contents:

```markdown

# Session Context
- Branch: add-user-search
- Database: wescomapp_dev_add_user_search
- Port: 3001
- PR: #123

This is an isolated worktree session. Your database is separate
from the main development database.

Use .session/memory/ to track decisions, progress, and context
about this work. Store session notes, decision logs, and progress
updates in .session/memory/ so they persist across conversations.
```

**Memory folder:** `.session/memory/` starts empty. Claude Code populates it during work — tracking decisions, progress, what was done and why. Persists across `ws attach` resumes since the worktree survives.

**Git exclude for session files:**
```sh
echo ".session/" >> "$worktree_path/.git/info/exclude"
```
This keeps `.session/` out of `git status` and prevents accidental commits.

### Tmux Layout

**Session name:** `ws-<branch-slug>` (slugified, e.g. `ws-feature-search` for branch `feature/search`)

**Layout:** Single window, vertical split (side by side):
```
+------------------------+------------------------+
|                        |                        |
|    Rails server        |    Claude Code         |
|    PORT=300X bin/dev   |    claude              |
|                        |                        |
+------------------------+------------------------+
```

**Creation:**
```sh
tmux new-session -d -s "$session_name" -c "$worktree_path"
tmux send-keys -t "$session_name" "PORT=$port bin/dev" Enter
tmux split-window -h -t "$session_name" -c "$worktree_path"
tmux send-keys -t "$session_name" "claude" Enter
tmux attach -t "$session_name"
```

**Resume:** If tmux session exists, `tmux attach`. If not, create fresh.

**Teardown:** `tmux kill-session -t "$session_name"`

### Session Registry

**Location:** `~/.wescom-sessions.json`

**Structure:**
```json
[
  {
    "branch": "add-user-search",
    "db": "wescomapp_dev_add_user_search",
    "port": 3001,
    "path": "/Users/lancefoley/code/wescom-sessions/add-user-search",
    "pr": 123,
    "started": "2026-03-16 14:30",
    "status": "active"
  }
]
```

**Used for:**
- `ws list`: display sessions
- `ws attach`: check for existing sessions, assign next available port
- `ws end`: mark status as `"ended"`

**Not used for:** Notion state, task titles, sync history — all removed.

**Pruning:** On each `ws attach` invocation, remove registry entries with `"status": "ended"` that are older than 30 days.

### File Structure of the Tool

```
wescom-session/
├── install.sh          # Check deps, symlink ws, set env vars
├── ws                  # Single script, ~200 lines
└── lib/
    ├── colors.sh       # Terminal output formatting (unchanged)
    └── database.sh     # PostgreSQL clone/drop utilities (unchanged)
```

**Removed:**
- `lib/notion.sh` — entirely removed
- `lib/worktree.sh` — useful bits (slugify, worktree create/remove) folded into `ws`; session notes and Notion helpers dropped

**Dependencies:**
- `git`, `psql`/`createdb`/`dropdb`, `gh`, `tmux`, `jq`
- `claude` (Claude Code CLI)
- RubyMine (opened via `open -a`)

**Install:**
- Checks for required tools
- Symlinks `ws` to PATH
- Prompts for `WESCOM_APP_PATH` (default: `~/code/WescomApp`), `PG_USER` (default: `$(whoami)`), and `PG_BASE_DB` (default: `wescom_app_development`)
- Validates `gh auth status` passes

## What's Removed vs Current

| Current | Redesign |
|---------|----------|
| 6 commands (new, attach, list, sync, pr, end) | 3 commands (attach, list, end) |
| ~850 lines across 6 files | ~200 lines across 3 files |
| Worktrees in `.claude/worktrees/` | Worktrees in `~/code/wescom-sessions/` |
| Auto-generated slug-timestamp branches | Real PR/feature branches with full history |
| Notion integration (create, sync, status updates) | Removed — Claude Code handles via MCP |
| Rails config patching (puma.rb, Procfile.dev, bin/dev) | `PORT` env var only |
| SESSION_NOTES.md + CLAUDE.md per session | `.session/memory/` + append to existing CLAUDE.md |
| tmux multi-window (server + code) | tmux split panes (server | claude) |
