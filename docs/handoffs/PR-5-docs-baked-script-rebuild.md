# Document the baked-script rebuild asymmetry

**Priority:** P2 · **Effort:** ~30 min · **Scope:** docs-only (README, two `.ws/` script header comments, CONTEXT.md) — no engine behavior change · **Base branch:** PR-1's branch (`<PR-1-branch>`, e.g. `p0-fixes` off `generalize-boxwood`); use `main` instead only if PR-1 has already merged · **Depends-on:** PR-1.

## Problem

`ws` treats two classes of session inputs differently, and the difference is invisible to a developer iterating on database-init logic:

1. **Baked at build time** — the `.ws/` Dockerfile `COPY`s `docker-entrypoint.sh` and `db-init.sh` *into* the golden base image. They live in `/usr/local/bin/` inside the image. Editing the source files on disk has **no effect** until `ws rebuild` rebuilds the image.
2. **Read live on every attach** — `docker-compose.template.yml` is substituted and consumed fresh by `ws` each time you attach, so edits to it take effect on the next `ws attach` with no rebuild.

This bit a real edit this session: a PK-assertion change to the WescomApp `db-init.sh` appeared to do nothing because the running session was using the version baked into the image, not the edited file on disk. The fix was `ws rebuild`, but nothing in the repo signals that.

### Verified current code (boxwood @ branch `generalize-boxwood`, HEAD)

**`templates/rails-postgres/.ws/Dockerfile:40-44`** — the scripts are baked in:

```dockerfile
# Entrypoint handles dependency drift and DB init; db-init.sh is the shared
# DB setup script (also invoked by `ws db-restore`).
COPY docker-entrypoint.sh db-init.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/db-init.sh
ENTRYPOINT ["docker-entrypoint.sh"]
```

**`ws:596-602` (inside `cmd_rebuild`)** — rebuild copies the scripts into the build context, so they are only refreshed at rebuild time:

```bash
# Dockerfile + any scripts it COPYs (entrypoint, db-init) from .ws/ into ctx root.
cp "$REPO_ROOT/$dockerfile" "$build_ctx/Dockerfile"
cp "$REPO_ROOT/.ws/docker-entrypoint.sh" "$build_ctx/" 2>/dev/null || true
cp "$REPO_ROOT/.ws/db-init.sh" "$build_ctx/" 2>/dev/null || true

info "Building image (this may take a few minutes on first run)..."
docker build -t "$image_name" "$build_ctx"
```

**`templates/rails-postgres/.ws/docker-compose.template.yml:1`** — the compose template is consumed live (substituted per session), not baked:

```yaml
# Per-session stack. boxwood substitutes __HOST_PORT__, __WORKTREE_PATH__,
# __REPO_ROOT__, and __DB_INIT__ when it generates the session's compose file.
```

**Why it matters:** adopters iterate on `db-init.sh` (especially when switching the starter's `rails db:prepare` to a `pg_restore` dump flow — see README "DB from a production dump") and on `docker-entrypoint.sh`. The live-vs-baked split is a silent footgun: compose edits "just work", script edits silently don't. A one-line troubleshooting entry plus header comments on the two scripts removes the trap.

> Note: the "WescomApp recipe Dockerfile" referenced in the originating task is **not** in this repo — the WescomApp `.ws/` recipe lives in the WescomApp repo. The same `COPY docker-entrypoint.sh db-init.sh` pattern is what bit there; this PR documents the behavior in boxwood's own starter + docs, which is what adopters copy from. Do not attempt to edit a WescomApp file from this repo.

## Required changes

All changes are documentation/comments only. Make them in this order.

### 1. README Troubleshooting entry

In `README.md`, the `## Troubleshooting` list (currently `README.md:219-226`), add a bullet. Suggested placement: right after the "Base image not found" bullet (keeps the rebuild-related items together).

```markdown
- **Edited `db-init.sh` or `docker-entrypoint.sh` and nothing changed?** — those scripts
  are baked into the golden base image at build time (the `.ws/Dockerfile` `COPY`s them in),
  so edits take effect only after `ws rebuild`. By contrast, `docker-compose.template.yml`
  is read fresh on every `ws attach` — compose edits are live, baked scripts are not.
```

### 2. Header comment in `templates/rails-postgres/.ws/db-init.sh`

The file already opens with a header comment block (`db-init.sh:1-12`). Add a line to that block noting the baked-at-build-time nature. Suggested: insert after the existing "Runs inside the app container…" line (currently line 8), before the blank line and the `rails db:prepare` note.

```bash
#
# NOTE: baked into the golden base image at build time (the .ws/Dockerfile COPYs it
# in). Editing this file has no effect on a running session until you `ws rebuild`.
```

### 3. Header comment in `templates/rails-postgres/.ws/docker-entrypoint.sh`

This file currently has no top comment (`docker-entrypoint.sh:1-2` is just the shebang + `set -e`). Add a short header comment immediately after `set -e` (line 2):

```bash
#!/bin/bash
set -e

# NOTE: baked into the golden base image at build time (the .ws/Dockerfile COPYs it
# in). Editing this file has no effect on a running session until you `ws rebuild`.
# (docker-compose.template.yml, by contrast, is read fresh on every attach.)
```

### 4. CONTEXT.md one-line note

In `CONTEXT.md`, add a one-line note capturing the live-vs-baked distinction. Two good homes — pick one (do not add both):

- Under the **Golden base image** definition (`CONTEXT.md:56-60`), append a sentence:
  > The `.ws/` `docker-entrypoint.sh` and `db-init.sh` are `COPY`d into this image, so edits to them require `ws rebuild`; `docker-compose.template.yml`, by contrast, is read fresh on every attach.

- Or under **DB init** (`CONTEXT.md:67-70`), append:
  > `db-init.sh` is baked into the **Golden base image** at build time, so editing it takes effect only after `ws rebuild` (unlike the compose template, which is live per attach).

Prefer the **Golden base image** placement — it owns the "baked in" concept and already says "Dependencies are baked in; app code, DB data, and secrets are not", which the new sentence extends naturally.

### 5. (Optional, scoped OUT) future-ADR breadcrumb

You MAY add one sentence to the README Troubleshooting bullet or a CONTEXT.md aside noting a future option: *mount `db-init.sh` / `docker-entrypoint.sh` read-only from the worktree so they are live-editable, trading rebuild speed for live iteration.* Do **not** implement that mount, write an ADR, or change any compose/Dockerfile/`ws` logic in this PR. If in doubt, omit it — it is genuinely optional.

## Out of scope / do NOT touch

- Any executable logic: `ws` (`cmd_rebuild` or otherwise), the Dockerfile `COPY`/`RUN` lines, the compose template, the body of `db-init.sh` or `docker-entrypoint.sh`. **Comments and docs only.**
- The test fixtures under `test/smoke/fixture*/.ws/` — leave their Dockerfiles/scripts alone.
- Writing a new ADR or actually implementing the read-only-mount option.
- Any file in the WescomApp repo (it is not part of this repo/PR).
- The P0 fixes folded in by PR-1 — those are PR-1's job; do not touch them here.

## Acceptance criteria

- [ ] README Troubleshooting has a bullet stating: edit `db-init.sh`/`docker-entrypoint.sh` → no effect until `ws rebuild`; the compose template is live.
- [ ] `templates/rails-postgres/.ws/db-init.sh` header comment notes it is baked at build time and needs `ws rebuild` after edits.
- [ ] `templates/rails-postgres/.ws/docker-entrypoint.sh` has an analogous header comment.
- [ ] `CONTEXT.md` carries the live-vs-baked distinction in one place (Golden base image, preferred).
- [ ] No executable line of any script, Dockerfile, compose template, or `ws` changed (diff is comments + markdown only).
- [ ] `bash -n` passes on the two edited shell scripts (comment edits must not break syntax).

## Verification

This is docs-only; the goal is "renders correctly, links resolve, no script broke". Run from the repo root (`/Users/lancefoley/code/boxwood`):

```bash
# 1. Comment-only edits must not break shell syntax.
bash -n templates/rails-postgres/.ws/db-init.sh
bash -n templates/rails-postgres/.ws/docker-entrypoint.sh
bash -n ws
# Expected: no output, exit 0 for each.

# 2. Full unit suite still green (proves no engine behavior drift).
bats test/
# Expected: all tests pass (was 59 passing pre-change; count unchanged).

# 3. Confirm the diff is docs/comments only — no removed/added executable lines.
git diff
# Expected: only added comment lines (prefixed with `#`) in the two .ws scripts,
# added markdown in README.md and CONTEXT.md. No changes to COPY/RUN/cp/docker build,
# the compose template, or any script body.

# 4. Sanity-confirm the asymmetry still exists in code (it should — we are only documenting it).
grep -n 'COPY docker-entrypoint.sh db-init.sh' templates/rails-postgres/.ws/Dockerfile
grep -n 'cp "$REPO_ROOT/.ws/db-init.sh"' ws
# Expected: both match (Dockerfile ~line 42, ws ~line 599).
```

`bash test/smoke.sh` is **not required** for this PR (no runtime behavior changes), but running it (needs Docker up) is harmless if you want belt-and-suspenders.

Optional render check: open `README.md`, `CONTEXT.md`, and this handoff in a markdown previewer and confirm headings/links resolve. The README already links `CONTEXT.md` at `README.md:242`; that link is unaffected.

## PR steps

**Branch:** create off PR-1's branch (or `main` if PR-1 has merged):

```bash
git checkout <PR-1-branch>      # e.g. p0-fixes ; or: git checkout main && git pull
git checkout -b docs-baked-script-rebuild-asymmetry
```

**Commit** (single commit is fine; docs-only):

```
docs: document the baked-script rebuild asymmetry

db-init.sh and docker-entrypoint.sh are COPY'd into the golden base image,
so editing them has no effect on a running session until `ws rebuild`.
docker-compose.template.yml, by contrast, is read fresh on every attach.
This split silently bit a db-init.sh edit during the WescomApp parity run.

Add a README Troubleshooting bullet, header comments on the two baked .ws/
scripts, and a one-line note under Golden base image in CONTEXT.md. Docs only;
no engine behavior change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**Open the PR** against the same base you branched from:

```bash
gh pr create --base <PR-1-branch-or-main> --title "Document the baked-script rebuild asymmetry" --body "$(cat <<'EOF'
## What
Documents the live-vs-baked split between the .ws/ scripts and the compose template:
- `db-init.sh` and `docker-entrypoint.sh` are baked into the golden base image at build
  time (`.ws/Dockerfile` COPYs them, `ws rebuild` refreshes them) — edits need `ws rebuild`.
- `docker-compose.template.yml` is read fresh on every `ws attach` — edits are live.

## Why
Editing a baked script and seeing no change is a silent footgun; it bit a db-init.sh
PK-assertion edit during the WescomApp parity run. Now signposted in the three places an
adopter would look: README Troubleshooting, the script headers themselves, and CONTEXT.md.

## Scope
Docs and comments only — no change to `ws`, the Dockerfile, the compose template, or any
script body. A future read-only-mount option (live-editable scripts, slower rebuilds) is
noted but intentionally left for a separate ADR/PR.

## Verification
- `bash -n` on the two edited scripts and on `ws` — clean.
- `bats test/` — all passing (count unchanged).
- `git diff` confirms comments + markdown only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
