# Generic orchestrator with repo-owned `.ws/` config

**Status:** accepted

`ws` is a repo-agnostic session orchestrator: it knows only how to create
worktrees, per-session Docker stacks, ports, tmux layouts, and Claude context. All
stack-specific detail (how to build the image, init the DB, run the dev server)
lives in a committed `.ws/` directory in each target repo (config.yml + Dockerfile +
compose template + entrypoint + optional db-init.sh). `ws` detects the repo from
`git rev-parse --show-toplevel` and reads its `.ws/config.yml`. WescomApp becomes the
first such config, behaving exactly as it did when the tool was Wescom-specific.

## Considered options

- **Tool owns built-in Rails/Postgres templates, config just fills in values.** Easier
  for simple Rails repos but bakes Rails assumptions into the tool and blocks genuinely
  different stacks. Rejected — defeats the goal of "works for any repo."
- **Hybrid: tool ships defaults, repo may override any asset.** More flexible than
  tool-owned but adds asset-resolution complexity (which Dockerfile wins?). Rejected for
  now in favor of the simpler repo-owned model; can revisit if scaffolding alone proves
  insufficient.

## Consequences

- `ws` ships no Dockerfile/compose; instead `ws init` scaffolds a starter `.ws/` that a
  repo customizes. The tool's own repo holds only orchestration logic.
- `WESCOM_APP_PATH` and all hardcoded `wescomapp`/Rails references are removed.
- A repo's session recipe is versioned and shareable with teammates (it's committed).
- Only Rails+Postgres is proven initially; other stacks are enabled but unexercised.
- Supersedes the Wescom-specific framing of ADR-0001 (the dev-server decision still
  holds, but now expressed via the repo's own compose template, not the tool's).
