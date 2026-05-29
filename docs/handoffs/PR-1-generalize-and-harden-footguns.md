# Generalize boxwood into a repo-agnostic orchestrator + harden first-run footguns

**Priority:** P0 · **Effort:** ~M (Part A done; Part B is 4 focused edits + tests) · **Scope:** engine (`ws`, `lib/colors.sh`, `lib/docker.sh`) + tests (`test/colors.bats`, `test/unit.bats`, `test/smoke.sh`) · **Base branch:** `generalize-boxwood` (HEAD `6a41dd5`) · **Depends-on:** nothing (this is the foundation for PR-2..PR-5).

> **READ FIRST:** `CONTEXT.md` (the project glossary) and `docs/adr/0003-agnostic-engine-per-user-config.md` (intent). This PR has **two parts**. **PART A is ALREADY IMPLEMENTED at `6a41dd5` — do NOT reimplement it.** Your job is: (1) confirm Part A builds/tests green, (2) implement Part B on top, (3) push + open the PR. The PART A summary below exists only so the PR description is accurate.

---

## PART A — already implemented at 6a41dd5 (DO NOT redo)

Commit `6a41dd5` ("Make boxwood a runtime-agnostic engine + add installer and test harness") already landed the generalization. Confirmed present on disk:

- **yq config parsing** — `lib/config.sh` parses `.ws/config.yml` via `yq -o=json` (no Ruby), cached in `CONFIG_JSON`, queried with `cfg`/`cfg_default`/`has_db`.
- **Per-user `~/.ws/config.yml`** — `load_user_config` loads `USER_CONFIG_JSON` (best-effort, defaults to `{}`); `ucfg`/`ucfg_default` read it. Recipe (`.ws/`) describes the *stack*; per-user config describes the *developer*.
- **Configurable editor + Assistant in `launch_tmux`** — in-tmux editor resolves per-user config → `$EDITOR` → `nvim`; the Assistant pane resolves via `resolve_assistant_command` (key absent → `claude`; present-but-blank → plain `bash`); optional external GUI editor via `ucfg '.gui_editor'`. Context block lands in `CLAUDE.md` for Claude, else `.session/CONTEXT.md`.
- **Test seams** — `WS_NO_ATTACH` (`launch_tmux` returns instead of `exec`-ing tmux) and `WS_ASSUME_YES` (auto-answer prompts).
- **Sourceable `ws`** — main-guard `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` (ws:700) lets tests source the engine without dispatching.
- **gh/origin hardening** — `cmd_attach` (ws:385-394) and `cmd_rebuild` (ws:570-577) degrade gracefully when there is no `origin` remote (local-only / GitLab repos): they probe `git remote get-url origin`, fall back to a local ref, then to `HEAD`.
- **Installer rewrite** — `install.sh` (macOS/Homebrew remote one-liner).
- **Test harness** — `bats` unit tests (`test/config.bats`, `test/docker.bats`, `test/unit.bats`; **59 passing** at HEAD) + an alpine-fixture smoke lifecycle (`test/smoke.sh`).

**Already-fixed, do NOT resurrect:** the `build_ctx`/EXIT-trap issue in `cmd_rebuild` is handled (ws:580-583 keeps `build_ctx` non-local with a `${build_ctx:-}` guard) and the rebuild fetch is already hardened with `|| true` (ws:571). The stale notes in `test/smoke.sh` (lines 132-143, 212-214) claiming "rebuild exits non-zero on success" / "needs `|| true`" are **out of date** — leave them; rewriting smoke.sh narrative is out of scope except the `ws end` flag change in Part B item 1.

---

## Problem

Four current footguns in the engine. Line numbers verified against HEAD `6a41dd5`.

### B1 (P0) — `WS_ASSUME_YES` auto-confirms *destructive* prompts

`lib/colors.sh:21-30`:
```bash
confirm() {
  local prompt="${1:-Continue?}"
  echo -en "${YELLOW}${prompt} [y/N]${NC} "
  if [[ -n "${WS_ASSUME_YES:-}" ]]; then
    echo ""
    return 0
  fi
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}
```
Under `WS_ASSUME_YES`, **every** prompt returns 0 — including the genuinely destructive ones. The five call sites (verified):

| ws line | prompt | destructive? | current assume-yes behavior |
|---|---|---|---|
| 364 | `Database exists from a previous run. Drop and re-initialize?` | **YES** (wipes the session DB) | auto-drops |
| 405 | `Remove stale worktree and continue?` | benign (recovers a stuck state) | auto-yes (fine) |
| 527 | `Push branch to origin?` (`cmd_end`) | **YES** (publishes work) | auto-pushes |
| 537 | `Remove worktree and local branch?` (`cmd_end`) | benign-but-logged | auto-yes (fine) |
| 663 | `Continue?` (`cmd_db_restore`, after `warn "This will reset…"`) | **YES** (resets DB) | auto-yes |

**Real-world bite:** any automation or smoke run that exports `WS_ASSUME_YES=1` silently drops a populated session database and pushes a branch to `origin` it never meant to publish.

### B2 (P0) — post-first-run container recreation hides failure

`lib/docker.sh:94-97`:
```bash
  if [[ "$state" == "first_run" ]]; then
    generate_compose "$worktree_path" "$host_port" "false"
    docker compose -p "$project" -f "$compose_file" up -d --wait --wait-timeout 120 >/dev/null 2>&1 || true
  fi

  success "Containers running on port $host_port"
```
The second `up -d` (which flips `DB_INIT=false` so a later restart never re-inits) is swallowed by `>/dev/null 2>&1 || true`. If that recreate fails, `compose_up` still prints `Containers running` and `cmd_attach` proceeds to launch tmux against a broken stack.

**Real-world bite:** a first run that fails the `DB_INIT=false` recreate looks successful; the dev attaches into a session whose app container is dead, with no logs and no error.

### B3 (P1) — `.ws/` silently gitignored

`cmd_init` (ws:248) does `cp -R "$src" "$dest"` and prints success, with no check that the repo's `.gitignore` will actually let `.ws/` be committed. A repo whose `.gitignore` excludes `.ws` (common — many repos ignore dot-dirs or have `.ws` from an unrelated tool) ends up with a scaffolded-but-uncommittable recipe.

**Real-world bite:** teammate clones the repo, the `.ws/` recipe was never committed (git silently ignored it), `ws attach` errors with "No .ws/config.yml found." The CONTEXT.md promise "commit `.ws/` so teammates get the same recipe" silently fails.

### B4 (P1) — detached-HEAD recovery can launch a broken worktree

`cmd_attach` resume path, ws:340-347:
```bash
    current_head=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
    if [[ "$current_head" == "DETACHED" ]]; then
      warn "Worktree is in detached HEAD state — attempting to fix..."
      git -C "$worktree_path" checkout "$branch" 2>/dev/null && success "Now tracking branch: $branch" \
        || git -C "$worktree_path" checkout -b "$branch" "origin/$branch" 2>/dev/null && success "Created and tracking: $branch" \
        || warn "Could not fix detached HEAD. Continuing..."
    fi
```
The `A && B || C && D || E` chain has the classic `&&`/`||` precedence trap. If `checkout "$branch"` **fails**, evaluation falls to `checkout -b "$branch" origin/$branch`; if *that* also fails, `&& success "Created and tracking…"` is skipped but its `|| warn "Could not fix…"` runs — and either way control falls through and the function keeps going: it allocates a port, runs `compose_up`, and `launch_tmux` against a worktree that is **still in detached HEAD**. Commits made in that session land on no branch and are lost on the next checkout.

**Real-world bite:** resuming a worktree that git left detached (e.g. after an interrupted rebase) launches a full session anyway; work committed there is orphaned.

---

## Required changes

Do these in order. After each, run `bash -n` on the touched file.

### B1 — destructive-aware `confirm` + audited call sites + `ws end` flags

**1a. Rewrite `confirm()` in `lib/colors.sh`** to take an optional default and split benign vs destructive under assume-yes. Under `WS_ASSUME_YES`, a benign prompt (default `Y`) auto-yeses; a destructive prompt (default `N`) auto-**NO**s (returns 1). **Always echo the auto-chosen answer** so headless logs show what happened, and never block on `read`.

```bash
# confirm [prompt] [default]
#   default 'Y' → benign  (Enter = yes; under WS_ASSUME_YES auto-yes)
#   default 'N' → destructive (Enter = no; under WS_ASSUME_YES auto-NO, returns 1)
# Default when omitted is 'N' (fail safe).
confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-N}"
  local hint="[y/N]"; [[ "$default" =~ ^[Yy]$ ]] && hint="[Y/n]"
  echo -en "${YELLOW}${prompt} ${hint}${NC} "
  if [[ -n "${WS_ASSUME_YES:-}" ]]; then
    if [[ "$default" =~ ^[Yy]$ ]]; then
      echo "y (auto)"; return 0
    else
      echo "n (auto)"; return 1
    fi
  fi
  local reply
  read -r reply
  [[ -z "$reply" ]] && reply="$default"
  [[ "$reply" =~ ^[Yy]$ ]]
}
```

**1b. Audit & annotate all five call sites in `ws`:**

- **ws:364** `confirm "Database exists from a previous run. Drop and re-initialize?"` → make it destructive (default `N`) AND gate it behind an explicit `--reset` flag on `ws attach`. Add `--reset)` to the `cmd_attach` arg loop (ws:261-268) setting a local `reset=""`/`reset=1`. Then the drop block becomes: only prompt/drop when `--reset` was passed (or when interactively confirmed). Suggested:
  ```bash
  if [[ "$state" != "first_run" ]] && project_has_volumes "$project" && has_db; then
    if [[ -n "$reset" ]] && confirm "Database exists from a previous run. Drop and re-initialize?" N; then
      compose_down "$project" "$worktree_path"; state="first_run"
    fi
  fi
  ```
  Net effect: under `WS_ASSUME_YES` without `--reset`, the DB is **preserved** (no drop). With `--reset`, the destructive prompt still auto-NOs under assume-yes UNLESS you ALSO want `--reset` to be the explicit yes — choose: treat `--reset` itself as the confirmation and skip `confirm` entirely when `-n "$reset"`. Recommended: `--reset` means "yes, drop" outright (drop the inner `confirm` when `--reset` is set; keep the destructive `confirm N` only for the interactive, no-flag path). Document whichever you pick in `usage` and the help text.
- **ws:405** `confirm "Remove stale worktree and continue?"` → benign (default `Y`): `confirm "Remove stale worktree and continue?" Y`. This recovers a stuck state; auto-yes under assume-yes is correct.
- **ws:527** `confirm "Push branch to origin?"` (`cmd_end`) → must **NOT** auto-push. Add explicit `--push` / `--no-push` flags to `ws end` (arg loop ws:488-494, local `push=""`). Behavior: if `--push` given → push without prompting; if `--no-push` given → skip; otherwise `confirm "Push branch to origin?" N` (destructive default-N, so assume-yes auto-NOs). Suggested:
  ```bash
  if [[ "$push" == "yes" ]] || { [[ -z "$push" ]] && confirm "Push branch to origin?" N; }; then
    git -C "$worktree_path" push -u origin "$branch" 2>/dev/null && success "Branch pushed" || warn "Push failed"
    echo ""
  fi
  ```
  where `--push` sets `push=yes`, `--no-push` sets `push=no`.
- **ws:537** `confirm "Remove worktree and local branch?"` (`cmd_end`) → benign-but-logged (default `Y`): `confirm "Remove worktree and local branch?" Y`. Tearing down the worktree is the whole point of `ws end`; auto-yes is correct, and `confirm` now echoes `y (auto)` so it is logged.
- **ws:663** `confirm "Continue?"` (`cmd_db_restore`, after the `warn "This will reset…"`) → destructive (default `N`): `confirm "Continue?" N`. This resets the DB; under assume-yes it now auto-NOs and `db-restore` exits 0 without resetting (the existing `|| exit 0` already handles a non-zero return).

**1c. Update `usage()` (ws:673-695)** to document the new flags:
```
  ws attach --new "description" [--reset]   Create a new branch + session
  ws end [--branch <name>] [--push|--no-push]   Tear down a session
```
(Add `[--reset]` to the relevant `ws attach` lines too.) Also fix the stale prerequisites line **ws:693** — it still lists `ruby`: change `git, jq, ruby, tmux, claude` to `git, jq, yq, tmux; claude (optional Assistant)`.

**1d. Add `test/colors.bats`** (new file; mirror the `load 'helper'` + `setup() { load_ws; }` style of `test/docker.bats`). Cover at minimum:
- benign auto-yes: `WS_ASSUME_YES=1; run confirm "ok?" Y` → `status -eq 0` and `output` contains `(auto)`.
- destructive auto-no: `WS_ASSUME_YES=1; run confirm "drop?" N </dev/null` → `status -ne 0` and `output` contains `(auto)`.
- no-stdin-hang: both of the above with `</dev/null` prove `confirm` never blocks on `read` under assume-yes.
- interactive default applied: `unset WS_ASSUME_YES; echo "" | confirm "ok?" Y` → 0; `echo "" | confirm "drop?" N` → non-zero. (Use the `bash -c "... source '$WS_BIN'; echo … | confirm …"` subshell form already used in `test/unit.bats:284-293` so a piped stdin reaches `read`.)

**1e. Fix the THREE existing `confirm` tests in `test/unit.bats:274-294`** — they assume the OLD signature and WILL break:
- ws:276 `confirm: WS_ASSUME_YES returns 0 with no input read` calls `confirm "Proceed?"` with no default. Under the new scheme that defaults to destructive-N and will **return 1** under assume-yes. Update it to pass an explicit benign default: `run confirm "Proceed?" Y </dev/null` and keep `status -eq 0`. (Or move these three tests into the new `test/colors.bats` and delete them from `unit.bats` — your call; do NOT leave duplicates.)
- ws:284 / ws:290 (interactive `y`/`n` without assume-yes) still pass as-is, but verify after the rewrite.

**1f. Update `test/smoke.sh` for the new `ws end` semantics.** Smoke runs with `WS_ASSUME_YES=1` (smoke.sh:28) and relies on `ws end` tearing the worktree down. After this change:
- The `Remove worktree and local branch?` prompt is benign default-`Y` → still auto-yeses, so teardown still works. **But verify**: the two `ws end --branch …` calls (smoke.sh:192 and 242) must still remove the worktree and set status `ended`. They should, because that prompt stays benign.
- The `Push branch to origin?` prompt is now destructive default-`N` → auto-NOs under assume-yes (good: the smoke repos are remote-less, so a push would fail anyway). No flag strictly required for teardown, but to be **explicit and future-proof**, change both teardown calls to `"$WS" end --branch "$BRANCH" --no-push` (smoke.sh:192) and `"$WS" end --branch "$DB_BRANCH" --no-push` (smoke.sh:242).
- The with-DB first run (smoke.sh:219) is a fresh `attach --new` (always `first_run` → no drop prompt fires), so no `--reset` is needed there. Confirm the run stays green.

### B2 — fail loudly on the post-first-run recreate (`lib/docker.sh`)

Replace `lib/docker.sh:94-97` so the second `up -d` is checked; on failure, tail the app service's logs and exit. Keep the 120s wait-timeout.

```bash
  # After a first run, reset DB_INIT so a later container restart never re-inits.
  # Rewriting the env recreates the app container (now with DB_INIT=false).
  if [[ "$state" == "first_run" ]]; then
    generate_compose "$worktree_path" "$host_port" "false"
    if ! docker compose -p "$project" -f "$compose_file" up -d --wait --wait-timeout 120; then
      error "Container recreation failed after first-run init (DB_INIT=false)."
      local app_service; app_service=$(cfg_default '.compose.app_service' 'app')
      docker compose -p "$project" -f "$compose_file" logs --tail 50 "$app_service" >&2 || true
      exit 1
    fi
  fi

  success "Containers running on port $host_port"
```
Note: `cfg_default` is defined in `lib/config.sh`, which `ws` sources before `lib/docker.sh`, so it is in scope here. `compose_file` is already a local in `compose_up`.

### B3 — warn when `.ws/` is gitignored (`cmd_init`, ws)

After the `cp -R "$src" "$dest"` at ws:248 (before or after the success header — put it right after the `cp`), add a check. Engine-side only; do not touch any consuming repo's `.gitignore`.

```bash
  cp -R "$src" "$dest"

  if git -C "$REPO_ROOT" check-ignore -q .ws 2>/dev/null; then
    warn ".ws/ is gitignored in this repo — teammates won't get the recipe."
    echo -e "  Fix: append ${BOLD}!.ws/${NC} to $REPO_ROOT/.gitignore so the recipe is committable."
    if confirm "Append '!.ws/' to .gitignore now?" Y; then
      printf '\n# boxwood session recipe (un-ignore)\n!.ws/\n' >> "$REPO_ROOT/.gitignore"
      success "Appended '!.ws/' to .gitignore"
    fi
  fi
```
(`confirm … Y` is benign — under assume-yes it auto-appends, which is the safe/helpful default. If you prefer init to be non-mutating without explicit consent, make it default-`N`; document the choice. The warn-loudly-with-remedy is the hard requirement; the offer-to-append is optional.)

### B4 — robust detached-HEAD recovery (`cmd_attach`, ws)

Replace the `&&/||` chain at ws:343-347 with explicit `if/elif` and a **re-check** afterward. If still detached, error and exit instead of launching.

```bash
    if [[ "$current_head" == "DETACHED" ]]; then
      warn "Worktree is in detached HEAD state — attempting to fix..."
      if git -C "$worktree_path" checkout "$branch" 2>/dev/null; then
        success "Now tracking branch: $branch"
      elif git -C "$worktree_path" checkout -b "$branch" "origin/$branch" 2>/dev/null; then
        success "Created and tracking: $branch"
      else
        warn "Automatic checkout failed."
      fi
      # Re-verify: never launch a session in detached HEAD.
      if ! git -C "$worktree_path" symbolic-ref --short HEAD >/dev/null 2>&1; then
        error "Worktree at $worktree_path is still in detached HEAD; refusing to launch."
        error "Fix manually: git -C \"$worktree_path\" checkout $branch"
        exit 1
      fi
    fi
```

---

## Out of scope / do NOT touch

- **PART A** — do not reimplement yq parsing, per-user config, editor/Assistant resolution, the seams, the main-guard, installer, or origin hardening. Only confirm it's green.
- The **already-fixed** `build_ctx`/EXIT-trap (ws:580-583) and the **already-hardened** rebuild fetch `|| true` (ws:571). Leave the stale "concerns" narrative comments in `test/smoke.sh` (lines 132-143, 212-214) — rewriting them is not this PR.
- Any **consuming repo's** `.gitignore` (e.g. WescomApp) — B3 is engine-side only (warn + offer to fix the *current* repo during `ws init`).
- PR-2..PR-5 scope. Do not pull future work forward.
- Behavior of `cmd_db_restore`'s `|| exit 0` (ws:663) — it already handles `confirm` returning non-zero; just pass the `N` default.

---

## Acceptance criteria

- [ ] `confirm()` takes an optional default; under `WS_ASSUME_YES` benign (`Y`) auto-yeses, destructive (`N`) auto-NOs (returns 1), and BOTH echo the auto-chosen answer (`y (auto)` / `n (auto)`). Never reads stdin under assume-yes.
- [ ] All five `confirm` call sites pass an explicit default matching the table above.
- [ ] `ws end` accepts `--push` and `--no-push`; with neither flag the push prompt is destructive-N (auto-NO under assume-yes). No accidental auto-push.
- [ ] `ws attach` accepts `--reset`; without it, an existing DB volume is **preserved** under assume-yes (no drop). `usage()` documents `--reset`, `--push`, `--no-push`.
- [ ] ws:693 prerequisites line no longer says `ruby`.
- [ ] `compose_up`'s second `up -d` is checked; on failure it tails the app service logs to stderr and `exit 1`s (no more silent `Containers running`). 120s wait-timeout preserved.
- [ ] `cmd_init` runs `git check-ignore -q .ws` after scaffolding and warns loudly with the `!.ws/` remedy (optionally offers to append).
- [ ] Detached-HEAD recovery is `if/elif/else` and re-checks `symbolic-ref --short HEAD`; still-detached → error + `exit 1`, never launches.
- [ ] New `test/colors.bats` covers benign-auto-yes, destructive-auto-no, and no-stdin-hang.
- [ ] The three pre-existing `confirm` tests in `test/unit.bats` are updated (or migrated to `colors.bats`) — no duplicates, none failing.
- [ ] `test/smoke.sh` updated: both `ws end` calls pass `--no-push`; smoke stays green.
- [ ] `bash -n` clean on `ws`, `lib/colors.sh`, `lib/config.sh`, `lib/docker.sh`, `test/smoke.sh`.
- [ ] `bats test/` passes (count grows beyond 59 with the new `colors.bats` cases).
- [ ] `bash test/smoke.sh` passes (Docker up).

---

## Verification

Run from the repo root (`/Users/lancefoley/code/boxwood`). All commands assume `generalize-boxwood` checked out with Part B applied.

**1. Syntax — must be silent (exit 0):**
```bash
for f in ws lib/colors.sh lib/config.sh lib/docker.sh test/smoke.sh; do bash -n "$f" || echo "FAIL: $f"; done
```
Expected: no output (every file parses).

**2. Confirm Part A baseline is intact, then run the full unit suite incl. new colors.bats:**
```bash
bats test/
```
Expected: all tests `ok`, `0 failures`. Baseline was **59** at HEAD; after adding `test/colors.bats` (≥4 cases) and updating the 3 existing confirm tests, expect **≥63** passing. Watch specifically that the updated `confirm:` tests in `unit.bats` (or their `colors.bats` replacements) pass.

**3. Targeted spot-check of the new confirm semantics (no bats needed):**
```bash
WS_ASSUME_YES=1 bash -c 'source lib/colors.sh; confirm "drop?" N </dev/null; echo "rc=$?"'   # expect: prints "drop? [y/N] n (auto)" and rc=1
WS_ASSUME_YES=1 bash -c 'source lib/colors.sh; confirm "keep?" Y </dev/null; echo "rc=$?"'   # expect: prints "keep? [Y/n] y (auto)" and rc=0
```

**4. Smoke lifecycle (requires Docker/OrbStack running):**
```bash
docker info >/dev/null 2>&1 && bash test/smoke.sh
```
Expected: a `PASS` line per step and a final `== ALL SMOKE STEPS PASSED`. Both `ws end --no-push` teardowns must remove the worktree and leave registry status `ended` with no surviving containers/volumes. If Docker is not running, start OrbStack first; do not skip this step before opening the PR.

---

## PR steps

1. **Confirm clean base.** `git status` clean, `git rev-parse HEAD` == `6a41dd5…` on `generalize-boxwood`. Run `bats test/` (expect 59) and `bash test/smoke.sh` (expect green) BEFORE any edits, to prove Part A is sound.
2. **Branch off `generalize-boxwood`:**
   ```bash
   git checkout generalize-boxwood
   git checkout -b harden-first-run-footguns
   ```
3. Implement Part B items B1→B4 in order; run the Verification block after each major edit.
4. **Commit** (one focused commit, or split B1 / B2-B4 if you prefer). Commit message body must end with the Co-Authored-By line:
   ```
   Harden first-run footguns: destructive-aware confirm, loud recreate failures

   - confirm() gains a benign/destructive default; WS_ASSUME_YES auto-NOs
     destructive prompts (DB drop, push) and echoes the auto answer
   - ws attach --reset / ws end --push|--no-push; DB preserved by default
   - compose_up fails loudly (tails app logs, exit 1) if the DB_INIT=false
     recreate fails, instead of printing "Containers running"
   - ws init warns + offers a fix when .ws/ is gitignored
   - cmd_attach detached-HEAD recovery: if/elif + re-check, refuses to launch
   - new test/colors.bats; updated unit.bats confirm tests; smoke.sh --no-push

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   ```
5. **Push** the branch: `git push -u origin harden-first-run-footguns`.
6. **Open the PR with `gh`** targeting `generalize-boxwood`:
   ```bash
   gh pr create --base generalize-boxwood --head harden-first-run-footguns \
     --title "Generalize boxwood into a repo-agnostic orchestrator + harden first-run footguns"
   ```
   **PR body outline:**
   - **Summary** — two parts: Part A (already landed at `6a41dd5`) is the runtime-agnostic generalization; Part B (this work) hardens four first-run footguns on top of it.
   - **Part A (context, already merged into this branch's base)** — yq config parsing, per-user `~/.ws/config.yml`, configurable editor + Assistant, `WS_NO_ATTACH`/`WS_ASSUME_YES` seams, sourceable `ws`, gh/origin hardening, installer rewrite, bats + smoke harness.
   - **Part B (changes in this PR)** — destructive-aware `confirm` + `--reset`/`--push`/`--no-push` flags; loud `compose_up` recreate failures; `ws init` gitignore warning; robust detached-HEAD recovery; new `test/colors.bats`, updated `unit.bats`, `smoke.sh --no-push`.
   - **Verification** — `bash -n` clean; `bats test/` ≥63 passing; `bash test/smoke.sh` green.
   - **Base branch** — `generalize-boxwood` (this is the P0 foundation; PR-2..PR-5 branch off it).
   - Last line of the body:
     ```
     🤖 Generated with [Claude Code](https://claude.com/claude-code)
     ```
