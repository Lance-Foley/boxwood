# Engine robustness polish + `ws update`; fix stale prereqs

- **Priority:** P2 · **Effort:** ~1-2 hrs · **Scope:** `ws` + `lib/docker.sh` (small, low-risk, independently revertable fixes) · **Base branch:** PR-1's branch (the branch PR-1 creates by folding the P0 fixes onto `generalize-boxwood`) · **Depends-on:** PR-1.
- **Heads-up (rebase):** This PR edits `ws` and `lib/docker.sh`, which PR-1 also touches (gh/origin hardening, seams). Branch off PR-1's branch (or off `main` once PR-1 has merged). Expect a trivial rebase if PR-1 lands first; the hunks here are in different functions than PR-1's, so conflicts should be mechanical.

This is a bundle of six independent, low-risk hardening fixes. Each is its own commit and its own line in the acceptance checklist, so any one can be dropped or reverted without affecting the others.

---

## Problem

All six findings were verified against current code at HEAD `6a41dd5` on branch `generalize-boxwood`. Line numbers below are the **current** ones.

### Finding 1 — `generate_compose()` sed substitution is fragile to sed metacharacters
`lib/docker.sh:22-27` (inside `generate_compose`, lines 11-28):

```sh
  sed \
    -e "s|__WORKTREE_PATH__|${worktree_path}|g" \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__HOST_PORT__|${host_port}|g" \
    -e "s|__DB_INIT__|${db_init}|g" \
    "$template" > "$output"
```

The replacement values are interpolated raw into the `s|…|…|` command. If `worktree_path` or `REPO_ROOT` contains `|` (the delimiter), `&` (backreference to the whole match), or a backslash, sed mis-substitutes or errors. **Real-world bite:** low — these paths are boxwood-controlled (`~/.ws/sessions/<repo>/<branch>/` and the repo root), and the slugifier strips most odd characters from branch names. But a repo cloned under a path containing `&` (legal on macOS/Linux) would silently corrupt the generated compose file. This is latent, not currently exploited.

### Finding 2 — `cmd_db_restore` passes `$restore_cmd` unquoted, relying on word-splitting
`ws:656` and `ws:667` (inside `cmd_db_restore`, lines 633-669):

```sh
  restore_cmd=$(cfg '.db.restore_command')
  …
  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec "$app_service" $restore_cmd
```

`$restore_cmd` is deliberately unquoted so the shell word-splits it into argv for `docker compose exec`. That works for a single token (`./.ws/db-init.sh`) but **breaks for any multi-word command** — e.g. `bundle exec rake db:restore` is split into `bundle`, `exec`, `rake`, `db:restore` and passed as four argv to `exec`, which runs `bundle` with those args directly (no shell), so any quoting, `&&`, redirection, or env-prefix in the configured command is lost. **Real-world bite:** medium — `restore_command` is a user-supplied config string in `.ws/config.yml`; the natural way to write it is as a shell command line.

### Finding 3 — `registry_prune` can compute an EMPTY cutoff and prune wrongly
`ws:53-60`:

```sh
registry_prune() {
  local cutoff tmp
  cutoff=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d")
  tmp=$(mktemp)
  jq --arg c "$cutoff" \
     '[.[] | select(.status == "active" or .started > $c)]' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}
```

On a host where **neither** `date -v-30d` (BSD/macOS) nor `date -d "30 days ago"` (GNU) succeeds, `cutoff` is the empty string. The jq filter then compares `.started > ""`, which is true for every non-empty `.started`, so the prune happens to keep everything — but the behavior is undefined-by-accident and would silently flip if the comparison or jq version changed. **Real-world bite:** low (both `date` forms cover macOS + Linux), but the code should fail safe explicitly rather than rely on a lucky string comparison. `registry_prune` is called from `cmd_attach` (`ws:293`) on every attach.

### Finding 4 — `cmd_db_restore` (and `cmd_exec`) only checks the app container is `running`, not that the db is healthy
`ws:658-660` (db-restore) and `ws:624-626` (exec):

```sh
  if [[ "$(compose_status "$project")" != "running" ]]; then
    error "Containers not running for '$branch'. Run 'ws attach --branch $branch' first."; exit 1
  fi
```

`compose_status` (`lib/docker.sh:39-52`) reports `running` if **any** service has a running container. The restore command runs the repo's `db-init.sh`, whose first step is an **unbounded** wait (`templates/rails-postgres/.ws/db-init.sh:16`):

```sh
until pg_isready -h db -U postgres -q; do sleep 1; done
```

If the app container is up but the `db` service is down/unhealthy, `ws db-restore` passes the guard and then **hangs forever** inside the container on `pg_isready` with no timeout and no actionable message. **Real-world bite:** medium — a session whose db crashed or was never healthy is exactly when a user reaches for `db-restore`, and they get a silent hang instead of a clear error.

### Finding 5 — no `ws update` command
There is no self-update path. `SCRIPT_DIR` (`ws:11`) already resolves the real install dir through symlinks (the installer symlinks `ws` onto `PATH`). A one-liner `git -C "$SCRIPT_DIR" pull --ff-only` gives users a first-class way to update their boxwood checkout. Currently they must `cd` into the clone manually. **Real-world bite:** minor UX gap; users have no obvious update command.

### Finding 6 — `usage()` lists `ruby` as a prerequisite, but the engine dropped Ruby
`ws:693`:

```sh
${BOLD}Prerequisites:${NC}
  Docker (OrbStack recommended), git, jq, ruby, tmux, claude; gh for --pr.
```

The runtime-agnostic refactor (ADR 0003) replaced Ruby-based config parsing with `yq` + `jq` (`lib/config.sh`). `ruby` is now stale in the prereq line. **Verified:** `ruby` appears in `ws` at exactly one place — line 693 — and nowhere else. The other repo matches for "ruby" are `RubyMine`/`rubymine` GUI-editor examples (`README.md:187`, `install.sh:123`) and historical design docs, none of which are prereq lists. The `README.md:43` prereq line already reads `git`, `jq` (no `ruby`) and is correct — leave it alone. **Real-world bite:** low (cosmetic), but it tells new users to install a dependency the tool no longer uses and omits `yq`, which it now requires.

---

## Required changes

Apply these as six separate commits (see PR steps). Intended code shown where it removes ambiguity.

### 1. `lib/docker.sh` — escape sed replacement values in `generate_compose`

Add a small escaper that neutralizes the sed delimiter `|`, the backreference `&`, and `\`, then use it for the two path-derived values (the port and the boolean db_init are numeric/boolean and safe, but escaping all four is simplest and harmless). Replace the body of `generate_compose` (lines 22-27) with:

```sh
  # Escape characters that are special on the replacement side of sed's s|…|…|:
  # the delimiter (|), the whole-match backreference (&), and backslash.
  local sed_esc='s/[&|\\]/\\&/g'
  local wt_e rr_e
  wt_e=$(printf '%s' "$worktree_path" | sed "$sed_esc")
  rr_e=$(printf '%s' "$REPO_ROOT"     | sed "$sed_esc")

  sed \
    -e "s|__WORKTREE_PATH__|${wt_e}|g" \
    -e "s|__REPO_ROOT__|${rr_e}|g" \
    -e "s|__HOST_PORT__|${host_port}|g" \
    -e "s|__DB_INIT__|${db_init}|g" \
    "$template" > "$output"
```

(If you prefer, escaping all four with the helper is also fine — pick one approach and keep it consistent. The two existing `generate_compose` bats tests use ordinary paths and must still pass unchanged.)

### 2. `ws` — run `$restore_cmd` through a single shell in `cmd_db_restore`

At `ws:667`, change the exec line so one shell parses the configured command line (preserving the user's intended quoting / pipelines / env-prefix):

```sh
  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec "$app_service" bash -lc "$restore_cmd"
```

Keep the existing `set -e` comment above it. Document in the config that `restore_command` is a **shell command line**, not an argv: update the comment/example for `db.restore_command` in `templates/rails-postgres/.ws/config.yml` and `install.sh`'s generated config comment if one exists there (grep `restore_command`). At minimum add a one-line note in `usage()` is **not** required; the config-file comment is the right home.

### 3. `ws` — fail safe in `registry_prune` when no `date` form works

Replace `registry_prune` (lines 53-60) with:

```sh
registry_prune() {
  local cutoff tmp
  cutoff=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d" 2>/dev/null) || true
  if [[ -z "$cutoff" ]]; then
    warn "registry_prune: could not compute a 30-day cutoff (no compatible 'date') — skipping prune."
    return 0
  fi
  tmp=$(mktemp)
  jq --arg c "$cutoff" \
     '[.[] | select(.status == "active" or .started > $c)]' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}
```

Skipping is the safe choice: it retains all registry entries (no data loss), and the next attach on a healthy host prunes normally.

### 4. `ws` — assert the db service is running/healthy before db-restore (and exec)

Add a helper near the other docker helpers in `lib/docker.sh` that reports whether a *named service* in a compose project has a running (and, where compose exposes it, healthy) container:

```sh
# True if a specific service in a compose project has a running container.
service_running() {
  local project="$1" service="$2" running
  running=$(docker compose -p "$project" ps "$service" --status running --format json 2>/dev/null | head -1)
  [[ -n "$running" && "$running" != "[]" ]]
}
```

Then in `cmd_db_restore`, after the existing `compose_status` guard (around `ws:660`) and **only when `has_db`**, assert the db service is up before running the restore. Use the configured db service name with a sensible default:

```sh
  local db_service; db_service=$(cfg_default '.compose.db_service' 'db')
  if ! service_running "$project" "$db_service"; then
    error "Database service '$db_service' is not running for '$branch'."
    error "Bring the session up first: ws attach --branch $branch"
    exit 1
  fi
```

Apply the same db assertion in `cmd_exec` *only when the command would depend on the db* is hard to detect generically, so for `cmd_exec` keep it lighter: this finding's required change for `cmd_exec` is **just the same `service_running` db guard, gated on `has_db`**, mirroring db-restore. If you judge the exec guard too aggressive (exec is also used for non-db commands), it is acceptable to scope the exec change down to a comment noting the limitation and leave the hard guard on db-restore only — call this out in the PR body. The db-restore guard is the must-have.

Optional (nice-to-have, not required): bound the `pg_isready` wait in `templates/rails-postgres/.ws/db-init.sh:16` with a retry cap so even a guarded-but-racing restore cannot hang forever:

```sh
echo "==> Waiting for PostgreSQL..."
tries=0
until pg_isready -h db -U postgres -q; do
  tries=$((tries + 1))
  if [[ "$tries" -ge 60 ]]; then echo "ERROR: PostgreSQL not ready after 60s" >&2; exit 1; fi
  sleep 1
done
```

If you do this, note it touches a **template** (affects only newly-scaffolded repos, not existing `.ws/` checkouts) and keep it in its own commit.

### 5. `ws` — add a `ws update` command

Add a command function near the others (e.g. after `cmd_db_restore`):

```sh
# ─── ws update ────────────────────────────────────────────────────────────────

cmd_update() {
  header "Updating boxwood"
  info "Pulling latest in $SCRIPT_DIR..."
  if git -C "$SCRIPT_DIR" pull --ff-only; then
    success "boxwood updated."
  else
    error "Update failed (not a fast-forward, or '$SCRIPT_DIR' is not a git checkout)."
    error "Resolve manually: git -C $SCRIPT_DIR pull"
    exit 1
  fi
}
```

Wire it into the dispatch `case` (around `ws:701-711`):

```sh
    update)     cmd_update ;;
```

And add it to `usage()` in the command list (after `db-restore`):

```
  ws update                          Update boxwood itself (git pull --ff-only)
```

### 6. `ws` — fix the stale prerequisites line in `usage()`

`ws:693` — change:

```sh
  Docker (OrbStack recommended), git, jq, ruby, tmux, claude; gh for --pr.
```

to:

```sh
  Docker (OrbStack recommended), git, jq, yq, tmux; claude (default assistant), gh for --pr.
```

(`claude` is the *default* assistant but is configurable/optional per ADR 0003, so it is demoted from the hard list. Keep it mentioned. The key corrections are: drop `ruby`, add `yq`.)

---

## Out of scope / do NOT touch

- **Do NOT** modify `cmd_attach`'s gh/origin hardening or `cmd_rebuild`'s `build_ctx`/EXIT-trap and fetch-hardening — those were already fixed (verified at HEAD; the `build_ctx` non-local + guard comment is intentional, `ws:579-583`). Do not "fix" them.
- **Do NOT** rewrite `compose_status` / `detect_session_state` — finding 4 adds a *new* per-service helper, it does not change the existing project-level status logic.
- **Do NOT** edit `README.md:43` prereqs (already correct — no `ruby`) or the `rubymine`/`RubyMine` GUI-editor examples (`README.md:187`, `install.sh:123`) — those are unrelated to the prereq fix.
- **Do NOT** change the slugifier, registry schema, port allocation, tmux layout, or per-user config logic.
- Keep each fix in its own commit; do not bundle unrelated refactors.

---

## Acceptance criteria

- [ ] **1.** `lib/docker.sh generate_compose` escapes `|`, `&`, `\` in `worktree_path` and `REPO_ROOT` before sed substitution; both existing `generate_compose` bats tests still pass; a new test proves a path containing `&` substitutes literally.
- [ ] **2.** `cmd_db_restore` invokes the restore via `bash -lc "$restore_cmd"`; a multi-word `restore_command` runs as one shell command line; `db.restore_command`'s config comment documents it as a shell command line.
- [ ] **3.** `registry_prune` assigns `cutoff` to a var, and when empty `warn`s and `return 0` (retains all entries) instead of running jq with an empty cutoff; existing `registry_prune` test still passes.
- [ ] **4.** `cmd_db_restore` asserts the db service is running (via new `service_running` helper, gated on `has_db`) with an actionable error before invoking the restore; the same guard (or a documented lighter treatment) is applied to `cmd_exec`; optional `pg_isready` bound, if added, is in its own commit and only touches the template.
- [ ] **5.** `ws update` runs `git -C "$SCRIPT_DIR" pull --ff-only`, is dispatched from the `case`, and is listed in `usage()`.
- [ ] **6.** `usage()` prereq line drops `ruby`, adds `yq`; `grep -n -i ruby ws` returns nothing.
- [ ] `bash -n` clean on all scripts; `bats test/` green (≥ 59, plus any new tests you add); smoke (if Docker up) green.

---

## Verification

Run from the repo root. Expected baseline before your changes: `bash -n` clean, **59** bats tests passing.

```sh
# 1. Syntax check every script (expect each line "… OK")
for f in ws lib/*.sh install.sh; do printf '%s: ' "$f"; bash -n "$f" && echo OK; done

# 2. Unit tests (expect all passing — 59 at baseline, more if you add tests)
bats test/
# … e.g. "59 tests, 0 failures" (or higher)

# 3. Confirm finding 6 is fully resolved (expect NO output)
grep -n -i ruby ws

# 4. Confirm ws update is wired (expect the usage line + the case arm)
ws --help | grep -i update          # shows "ws update …"
grep -n 'update)' ws                # shows the dispatch arm

# 5. Smoke / full lifecycle — ONLY if Docker is running.
#    Exercises rebuild → attach → resume → restart → list → exec → end on alpine
#    fixtures, headless via WS_NO_ATTACH / WS_ASSUME_YES seams. Expect a PASS
#    line per step and exit 0.
bash test/smoke.sh
```

**Suggested new bats tests** (add to `test/unit.bats`, following the existing patterns — `load_ws`, `export CONFIG_JSON=…`, `run …`):

- `generate_compose: escapes '&' in worktree path` — set `REPO_ROOT`/`wt` to a path containing `&`, run `generate_compose`, assert the literal `&`-path appears in the output and no sed corruption (`grep -qF "$wt:/app"`).
- `registry_prune: empty cutoff retains all entries` — stub `date` on PATH to fail (or temporarily shadow it) so `cutoff` is empty; seed the registry; assert `registry_prune` keeps every entry and emits the warn. (If stubbing `date` is awkward in bats, at minimum assert the function `return 0`s and does not error when `cutoff=""` by setting it directly in a small wrapper.)
- `cmd_update: pull --ff-only is invoked against SCRIPT_DIR` — optional; can be covered by asserting the dispatch arm exists and `usage` mentions it rather than executing a real git pull.

---

## PR steps

**Branch name:** `engine-robustness-polish` (off PR-1's branch — confirm the base with `git branch --show-current` before branching; if PR-1 has merged to `main`, branch off `main`).

```sh
# from PR-1's branch (or main if PR-1 merged):
git switch -c engine-robustness-polish
```

**Commits** (one per fix; bodies end with the Co-Authored-By line):

1. `fix(docker): escape sed metacharacters in generate_compose`
2. `fix(db-restore): run restore_command via bash -lc so quoting is preserved`
3. `fix(registry): skip prune when no compatible date yields an empty cutoff`
4. `fix(db-restore): assert db service is healthy before restore` (+ optional separate commit `chore(template): bound pg_isready wait in db-init.sh`)
5. `feat(ws): add 'ws update' (git pull --ff-only on the install dir)`
6. `docs(usage): fix stale prereqs — drop ruby, add yq`

Each commit body should be a one-or-two-line "why", and **must** end with exactly:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**Open the PR:**

```sh
gh pr create \
  --base <PR-1-branch-or-main> \
  --title "Engine robustness polish + ws update; fix stale prereqs" \
  --body "$(cat <<'BODY'
## Summary
Six small, independently-revertable engine hardening fixes (P2), each in its own commit:

1. `generate_compose` escapes sed metacharacters (`&`, `|`, `\`) in path-derived replacement values.
2. `ws db-restore` runs `restore_command` via `bash -lc` so multi-word / quoted shell command lines work.
3. `registry_prune` fails safe (warn + retain all) when neither `date` form yields a cutoff.
4. `ws db-restore` (and `ws exec`) assert the db service is up before invoking, so a missing db no longer hangs on `pg_isready`. (Optional: bounded `pg_isready` wait in the rails-postgres template.)
5. New `ws update` command — `git -C "$SCRIPT_DIR" pull --ff-only` — listed in usage.
6. `usage()` prereqs corrected: dropped `ruby` (removed in the runtime-agnostic refactor), added `yq`.

## Base / dependency
Branches off PR-1 (P0 foundation). Touches `ws` and `lib/docker.sh`, which PR-1 also edits — rebase expected if PR-1 lands first; hunks are in different functions.

## Verification
- `bash -n` clean on all scripts.
- `bats test/` green (59 baseline + new escaping/prune tests).
- `bash test/smoke.sh` green (full alpine lifecycle, Docker up).
- `grep -i ruby ws` → no output.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
