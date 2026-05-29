# PR-3: Expand smoke + unit coverage: --pr, db-restore, app-serves; drop stale comments

- **Priority:** P1 · **Effort:** M (~half day) · **Scope:** `test/smoke.sh`, `test/smoke/fixture/.ws/*` (only if you do the optional HTTP-liveness item), `test/unit.bats` (optional `--pr` jq unit), `test/README.md` (wording). NO changes to `ws` or `lib/`. · **Base branch:** PR-1's branch (`<pr-1-branch>`, e.g. `p0-fixes` folded onto `generalize-boxwood`); if PR-1 has already merged, branch off `main`. · **Depends-on:** PR-1 (foundation). See "Overlap with PR-2" below before editing the rebuild section.

This PR is test-only. It does not change engine behavior. Its job is to (a) close three coverage gaps in the smoke harness (`ws attach --pr`, `ws db-restore`, "the app actually serves"), and (b) delete stale comments in `test/smoke.sh` that describe two bugs which are ALREADY FIXED in `ws`.

---

## Problem

### Finding 1 — `ws attach --pr` (gh branch resolution) is untested

`cmd_attach` resolves a PR number to a branch via `gh` then `jq`. Verified current code, `ws` lines 296-304:

```sh
# Resolve branch from PR
if [[ -n "$pr_number" ]]; then
  info "Resolving branch from PR #${pr_number}..."
  local pr_json
  pr_json=$(cd "$REPO_ROOT" && gh pr view "$pr_number" --json headRefName 2>/dev/null) || {
    error "PR #${pr_number} not found."; exit 1
  }
  branch=$(echo "$pr_json" | jq -r '.headRefName')
  success "PR #${pr_number} → branch: $branch"
fi
```

`test/smoke.sh` drives `attach --new`, `attach --branch` (resume), `attach --branch` (restart), `list`, `exec`, `end` (lines 150-198 for the no-DB fixture; 219-242 for the DB fixture) but NEVER `attach --pr`. The whole `gh pr view … --json headRefName | jq -r '.headRefName'` path — the only place boxwood shells out to `gh` — has zero automated coverage. **Real-world bite:** a regression in the jq expression (`.headRefName`), the `gh` flag, or the `2>/dev/null`/error handling would ship undetected; `--pr` is a primary day-one entry point for picking up an open PR.

### Finding 2 — `ws db-restore` (`cmd_db_restore`) is untested

Verified current code, `ws` lines 633-669. The DB fixture's `config.yml` declares `db.restore_command: /usr/local/bin/db-init.sh` and that script exists (`test/smoke/fixture-db/.ws/db-init.sh`). The command:

```sh
warn "This will reset the session database via: $restore_cmd"
confirm "Continue?" || exit 0
info "Restoring database..."
# set -e propagates a non-zero exit straight out of ws.
docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec "$app_service" $restore_cmd
success "Database restore complete"
```

The smoke harness already brings up the DB fixture to a healthy `first_run` (lines 219-240) but tears it straight down with `ws end` — it never calls `ws db-restore`. So the gating (`has_db || error`, "containers not running" guard), the `confirm` path, and the `docker compose … exec <restore_cmd>` invocation are unverified. **Real-world bite:** `db-restore` is the recovery button after a bad migration; if the exec invocation or arg-splitting of `$restore_cmd` breaks, the user discovers it exactly when they most need it.

Note on confirmation: there is **no `--reset` flag** in `cmd_db_restore` on the current branch (verified). It gates purely on `confirm "Continue?"` (`ws:663`), which `confirm()` (`lib/colors.sh:21-30`) auto-answers when `WS_ASSUME_YES` is set. The smoke harness already exports `WS_ASSUME_YES=1` (`test/smoke.sh:28`), so `ws db-restore` will run non-interactively as-is. If PR-1 (or PR-2) introduces a `--reset` flag or new confirm semantics, prefer that flag here; otherwise rely on the existing `WS_ASSUME_YES`. Check the actual `cmd_db_restore` on your base branch before writing the assertion.

### Finding 3 — "the app actually SERVES" is never asserted

The smoke harness only asserts containers are **running/healthy** (`project_running_count … -ge 1`, `ps --status running --services | grep -qx app`, lines 158-159, 231-236). The no-DB fixture's `CMD` is `tail -f /dev/null` (verified, `test/smoke/fixture/.ws/Dockerfile:11`) and its compose maps `__HOST_PORT__:__HOST_PORT__` (`test/smoke/fixture/.ws/docker-compose.template.yml:11-12`) but nothing listens on that port. So "healthy" today means "the entrypoint didn't crash," not "the app answers." **Real-world bite:** a session can be green in `ws list`/healthcheck yet serve nothing — the exact failure the smoke suite is supposed to catch. (This item is the lowest-confidence/highest-cost of the three; see "Required changes" item 3 for the optional, bounded recipe.)

### Finding 4 — stale comments asserting ALREADY-FIXED bugs

`test/smoke.sh` carries comments describing two bugs that **no longer exist** in `ws`. Verified both are fixed on the current branch:

- **Stale comment A — "rebuild fetches unconditionally"** — `test/smoke.sh:131-136`:
  > `NOTE: \`ws rebuild\` runs \`git fetch origin\` unconditionally (no \`|| true\`), so a truly remote-less repo aborts rebuild under \`set -e\`. … (See concerns: rebuild should gain \`|| true\`.)`

  FIXED in `ws:568-575`: the fetch is now both **guarded** by an origin check and has `|| true`:
  ```sh
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO_ROOT" fetch origin >/dev/null 2>&1 || true
    src_ref="origin/$main_branch"
  else
    src_ref="$main_branch"
  fi
  ```
  A remote-less repo no longer aborts rebuild. The smoke workaround that adds/removes a self-referential `origin` (lines 138-139, 145, 210, 215) is **no longer required** for this reason.

- **Stale comment B — "rebuild exits non-zero on success via the EXIT trap"** — `test/smoke.sh:140-143` (and the echo of it at 212-213):
  > `NOTE: \`ws rebuild\` currently exits non-zero on success because its EXIT trap (\`rm -rf "$build_ctx"\`) dereferences a function-local under \`set -u\` after the function has returned. … (See concerns.)`

  FIXED in `ws:579-583`: `build_ctx` is now intentionally a **global** and the trap is guarded:
  ```sh
  # build_ctx is intentionally NOT local: the EXIT trap fires in global scope,
  # where a function-local would be unset (fatal under set -u, and would leak
  # the temp dir). The guard keeps the trap safe even if mktemp never ran.
  build_ctx=$(mktemp -d)
  trap 'rm -rf "${build_ctx:-}" 2>/dev/null' EXIT
  ```
  `ws rebuild` now exits 0 on success, so `( cd "$REPO" && "$WS" rebuild ) || true` (lines 144, 214) masks a real failure where it should not. **Real-world bite of leaving these:** the `|| true` swallows genuine rebuild failures (you'd only catch them via the downstream image-inspect assertion, with a confusing error), and the comments actively mislead the next reader into thinking two fixed bugs are still open — they will not "fix" them and may re-introduce the workarounds elsewhere.

---

## Required changes (ordered)

> Read the smoke harness end-to-end first; reuse its existing helpers (`make_repo`, `project_name`, `active_count`, `registry_status`, `project_running_count`, `pass`/`fail`/`step`). Keep the per-step `PASS/FAIL` style and `set -euo pipefail` discipline. The harness invokes the engine as `"$WS"` (absolute path, line 21), so a PATH-prepended stub only affects the subprocesses `ws` itself spawns (e.g. `gh`), which is exactly what we want.

### Change 0 — remove the stale comments and now-unneeded workarounds (do this first)

In `test/smoke.sh`:

1. Delete the stale comment block at **lines 131-136** (the "fetch unconditionally" NOTE). Keep the `step "(c) ws rebuild …"` line.
2. Delete the stale comment block at **lines 140-143** (the "exits non-zero on success" NOTE).
3. Replace the masking invocation `( cd "$REPO" && "$WS" rebuild ) || true` (**line 144**) with a checked call:
   ```sh
   ( cd "$REPO" && "$WS" rebuild ) || fail "ws rebuild (no-DB) failed"
   ```
4. In Phase 2, delete the stale echo at **lines 212-213** and replace `( cd "$DB_REPO" && "$WS" rebuild ) || true` (**line 214**) with:
   ```sh
   ( cd "$DB_REPO" && "$WS" rebuild ) || fail "ws rebuild (with-DB) failed"
   ```

**Decide on the self-referential-origin dance (lines 138-139/145 and 210/215):** it was added "JUST for rebuild" because of fetch finding A. Since rebuild now handles remote-less repos natively, you may remove the `git remote add origin … / fetch / remote remove origin` lines so the repos stay genuinely remote-less through rebuild too (stronger test of the remote-less hardening). **Caveat:** confirm via `bash test/smoke.sh` that rebuild's `git show "$src_ref:$f"` step still works with `build_context_from_main: []` (both fixtures set it empty, so the copy loop is a no-op and there is nothing to read from `origin/main`) — it should. If removing the dance makes any step flaky, keep the dance but still drop the stale comments. Either way, **do not** leave `|| true` on the rebuild calls.

### Change 1 — cover `ws attach --pr` via a PATH-shimmed `gh`

Add a phase **after** the no-DB lifecycle teardown, or fold into a fresh no-DB repo+branch so it doesn't collide with the existing `smoke-one` session. Two options; **prefer (a)** (true end-to-end), fall back to **(b)** if you want zero new containers.

**(a) End-to-end smoke phase (preferred).** Create a stub `gh` on a temp dir prepended to `PATH`, emitting canned JSON for the branch you will create, then assert `ws attach --pr <n>` resolves it and attaches:

```sh
# ── (j) attach --pr — gh branch resolution ──────────────────────────────────────
step "(j) ws attach --pr 7 — resolves headRefName via gh, then attaches"
PR_REPO_NAME="boxwood-smoke-pr"
PR_BRANCH="pr-seven"
PR_REPO="$(make_repo "$FIXTURE_NODB" "$PR_REPO_NAME")"
PR_PROJECT="$(project_name "$PR_REPO_NAME" "$PR_BRANCH")"
PROJECTS+=("$PR_PROJECT")

# rebuild the image for this repo (reuses boxwood-smoke:latest name? NO — config
# pins image.name to boxwood-smoke:latest in this fixture, so the image already
# exists from phase 1's rebuild IF phase 1 didn't `ws end`-remove it. ws end does
# NOT remove the base image, so boxwood-smoke:latest is still present. Skip rebuild.)
docker image inspect boxwood-smoke:latest >/dev/null 2>&1 \
  || ( cd "$PR_REPO" && "$WS" rebuild ) || fail "ws rebuild for --pr phase failed"

# The branch the PR "points at" must exist locally for the worktree checkout to
# succeed (remote-less repo). Create it off main.
git -C "$PR_REPO" branch "$PR_BRANCH" main

# PATH-shim gh to emit exactly what `gh pr view <n> --json headRefName` returns.
GH_STUB_DIR="$(mktemp -d)"; TMP_DIRS+=("$GH_STUB_DIR")
cat > "$GH_STUB_DIR/gh" <<SH
#!/usr/bin/env bash
# Minimal gh stub: only supports \`gh pr view <n> --json headRefName\`.
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  echo '{"headRefName":"$PR_BRANCH"}'
  exit 0
fi
exit 1
SH
chmod +x "$GH_STUB_DIR/gh"

( cd "$PR_REPO" && PATH="$GH_STUB_DIR:$PATH" "$WS" attach --pr 7 ) \
  || fail "attach --pr failed"

PR_WORKTREE="$WS_HOME/sessions/$PR_REPO_NAME/$(slugify "$PR_BRANCH")"
[[ -d "$PR_WORKTREE" ]] || fail "attach --pr did not create worktree for resolved branch $PR_BRANCH"
[[ "$(active_count "$PR_REPO_NAME" "$PR_BRANCH")" == "1" ]] \
  || fail "attach --pr: expected 1 active entry for $PR_BRANCH, got $(active_count "$PR_REPO_NAME" "$PR_BRANCH")"
# The PR number should be recorded on the registry entry.
[[ "$(jq -r --arg r "$PR_REPO_NAME" --arg b "$PR_BRANCH" \
   '.[] | select(.repo==$r and .branch==$b and .status=="active") | .pr' "$WS_HOME/registry.json" | head -1)" == "7" ]] \
  || fail "attach --pr: registry .pr not 7"
pass "gh resolved PR #7 → $PR_BRANCH; worktree + active entry created, pr=7 recorded"

( cd "$PR_REPO" && "$WS" end --branch "$PR_BRANCH" ) || fail "attach --pr cleanup end failed"
```

Notes for the implementer:
- Confirm the base image name: this fixture's `image.name` is `boxwood-smoke:latest` (same as phase 1). `ws end` does NOT remove base images (only `down -v` containers/volumes), so the image survives phase 1; the `image inspect || rebuild` guard above is belt-and-suspenders.
- Whether `cmd_attach` records `.pr` for a brand-new (first_run) worktree: verify on your base branch. In current `ws`, the first-run path (lines 379+, not shown here) calls `registry_add … "${pr_number:-null}"`. If the assertion on `.pr == "7"` proves brittle on the first-run path, downgrade it to asserting only worktree + active entry + the branch name, and keep the `.pr` assertion only if it holds.

**(b) Low-cost sourced unit instead (fallback).** If you'd rather not spin a container for this, add a bats test (in `test/unit.bats`, which sources `ws`) that asserts the extraction expression boxwood uses — `jq -r '.headRefName'` against canned `gh` JSON — matches the engine:

```sh
@test "attach --pr: headRefName is extracted from gh JSON" {
  run jq -r '.headRefName' <<<'{"headRefName":"feature/login","number":7}'
  [ "$status" -eq 0 ]
  [ "$output" = "feature/login" ]
}
```

This is weaker (it tests the jq, not `cmd_attach`'s wiring) — use it only if (a) proves too flaky. Prefer (a).

### Change 2 — cover `ws db-restore` in the DB phase

In Phase 2, after the `first_run` assertions pass (after **line 240**) and **before** `ws end` (line 242), insert a db-restore step against the still-running fixture:

```sh
# ── (k) db-restore — re-run the repo's DB setup against the live session ─────────
step "(k) ws db-restore --branch $DB_BRANCH — re-runs restore_command in the app container"
( cd "$DB_REPO" && "$WS" db-restore --branch "$DB_BRANCH" ) \
  || fail "ws db-restore failed (exit non-zero)"
# Session must still be running afterward (restore must not tear anything down).
[[ "$(project_running_count "$DB_PROJECT")" -ge 2 ]] \
  || fail "db-restore: app+db not both running afterward, got $(project_running_count "$DB_PROJECT")"
[[ "$(active_count "$DB_REPO_NAME" "$DB_BRANCH")" == "1" ]] \
  || fail "db-restore altered the active entry count"
pass "db-restore exit 0; app+db still running, registry unchanged"
```

Notes for the implementer:
- The fixture's `restore_command` is `/usr/local/bin/db-init.sh`, which is baked into the image (`Dockerfile` COPYs it to `/usr/local/bin/`) and waits on `pg_isready -h db` then echoes `ready`. Since db is up by this point, it exits 0 quickly.
- Non-interactive: `WS_ASSUME_YES=1` is already exported, so `confirm "Continue?"` auto-passes (`ws:663`). **If PR-1 added a `--reset` flag** to `cmd_db_restore`, pass it instead (e.g. `"$WS" db-restore --branch "$DB_BRANCH" --reset`) per PR-1's contract — check `cmd_db_restore` on your base branch and match whatever it actually accepts. Do not invent a flag that isn't there.
- `cmd_db_restore` runs `docker compose … exec "$app_service" $restore_cmd` with `$restore_cmd` unquoted (intentional word-splitting for multi-word commands). The single-token fixture command works either way; no change needed.

### Change 3 — assert the app actually serves (OPTIONAL, bounded)

Only do this if you want the stronger "serves" guarantee; it requires editing the no-DB fixture image because today's `CMD` is `tail -f /dev/null` (nothing listens). Keep it contained to the no-DB fixture so the lifecycle phase stays fast. Recipe:

1. In `test/smoke/fixture/.ws/Dockerfile`, install busybox httpd (alpine has it built in) and serve a one-byte page on `$PORT`. Replace the `CMD`:
   ```dockerfile
   # Serve a trivial page so the smoke suite can prove the app actually answers.
   RUN mkdir -p /srv && echo ok > /srv/index.html
   CMD ["sh","-c","httpd -f -p ${PORT:-3100} -h /srv"]
   ```
   (busybox `httpd` is part of the base `alpine:latest` image — no extra `apk add`. `-f` = foreground so the container stays up and compose can healthcheck it.)
2. Update the no-DB fixture's compose healthcheck (`test/smoke/fixture/.ws/docker-compose.template.yml:17-23`) to probe HTTP instead of the marker file, e.g.:
   ```yaml
   test: ["CMD-SHELL", "wget -qO- http://localhost:${PORT}/ >/dev/null 2>&1"]
   ```
   (busybox `wget` is also in alpine.) Keep `interval/timeout/retries/start_period` modest.
3. In `test/smoke.sh` phase 1, after the `attach --new` assertions (after line 163), add a host-side liveness curl against the assigned `$PORT`:
   ```sh
   step "(d2) HTTP liveness — app answers on port $PORT"
   curl -fsS "http://localhost:$PORT/" >/dev/null 2>&1 || fail "app not serving on $PORT"
   pass "app answers HTTP 200 on $PORT"
   ```

**If you skip this item, say so explicitly in the PR body** and leave the no-DB fixture as the marker-file healthcheck. The DB fixture is intentionally NOT given a listener (its job is the volume/db-init path). Mark Change 3 as optional in your acceptance criteria.

### Change 4 — update `test/README.md` wording (small)

`test/README.md:71-76` lists `cmd_db_restore` and `cmd_attach` under "intentionally NOT unit-tested … better covered by integration tests." After this PR, the smoke harness covers `attach --pr` and `db-restore`. Adjust the wording so it reads that these flows are covered by the **Tier-2 smoke harness** (`test/smoke.sh`), not "uncovered." Do not overclaim — `attach --branch`/`--new`/`end`/`exec`/`rebuild` and now `--pr` + `db-restore` are smoke-covered; the rest of the prose is still accurate.

---

## Out of scope / do NOT touch

- **`ws` and `lib/*.sh`** — no engine changes. This is a test-only PR. (If you discover db-restore/attach actually need a fix, STOP and surface it; do not fold an engine fix into this PR — it belongs in PR-1 or its own.)
- **Do NOT re-introduce** the `build_ctx`/EXIT-trap workaround or the rebuild `|| true` masking — both underlying bugs are fixed (see Finding 4). Removing them is the point.
- The **DB fixture's** marker-file healthcheck and absence of a listener — leave as-is (Change 3 touches only the no-DB fixture).
- `test/unit.bats`/`config.bats`/`docker.bats` existing cases — do not modify; only ADD the optional `--pr` jq unit if you took fallback 1(b).
- tmux/editor/assistant launch paths — covered by the `WS_NO_ATTACH` short-circuit; not in scope here.

## Acceptance criteria

- [ ] Stale comment blocks at `test/smoke.sh:131-136` and `:140-143` (and the echo at `:212-213`) are removed.
- [ ] Both `ws rebuild` invocations are checked (`|| fail …`), not masked with `|| true`.
- [ ] A new smoke phase exercises `ws attach --pr <n>` with a PATH-shimmed `gh` and asserts the resolved branch's worktree + active registry entry are created (option (a)); OR, if (a) proved flaky, a sourced `jq -r '.headRefName'` unit is added (option (b)) and the PR body explains why.
- [ ] A new smoke step runs `ws db-restore` against the live DB fixture and asserts exit 0 + app & db still running + active-entry count unchanged.
- [ ] (OPTIONAL) HTTP-liveness: no-DB fixture serves and a host-side `curl` asserts a 200 — OR the PR body states this was intentionally deferred.
- [ ] `test/README.md` no longer claims `attach`/`db-restore` are entirely uncovered; it points at the smoke harness.
- [ ] `bash -n` clean on every script; `bats test/` stays green (≥ 59, or 60 if the optional `--pr` jq unit was added); `bash test/smoke.sh` exits 0 with new PASS lines and no FAIL.

## Verification

Run from the repo root.

```sh
# 1. Syntax — every script must parse.
bash -n ws
for f in lib/*.sh test/smoke.sh; do bash -n "$f" && echo "$f OK"; done
```
Expected: `ws` and each listed file print `OK` (or no output for `bash -n ws`), exit 0.

```sh
# 2. Unit suite — must stay green.
bats test/
```
Expected tail: `59 tests, 0 failures` (or `60 tests, 0 failures` if you added the optional `--pr` jq unit in `test/unit.bats`). With `yq` absent, `config.bats` cases SKIP (still 0 failures) — `brew install yq` to run them all.

```sh
# 3. Smoke lifecycle — needs Docker (OrbStack) running.
docker info >/dev/null 2>&1 && echo "docker up" || echo "START DOCKER FIRST"
bash test/smoke.sh
```
Expected: a `PASS` line per step including the NEW steps — `(j) … gh resolved PR #7 → pr-seven …`, `(k) … db-restore exit 0; app+db still running …`, and (if Change 3 done) `(d2) … app answers HTTP 200 on <port>` — ending with `== ALL SMOKE STEPS PASSED`, exit 0. The `== cleanup` block must remove all compose projects, images, and temp dirs.

```sh
# 4. Negative check — the stale comments are gone.
grep -n 'unconditionally\|exits non-zero on success' test/smoke.sh || echo "stale comments removed"
```
Expected: prints `stale comments removed` (grep finds nothing).

## PR steps

**Branch:** off PR-1's branch — `git switch <pr-1-branch> && git switch -c test-coverage-pr-db-restore-serves` (or off `main` if PR-1 is merged). State the actual base in the PR.

**Commit** (test-only; group logically, or one commit is fine):

```
test: cover attach --pr + db-restore + app-serves; drop stale smoke comments

Add smoke phases for `ws attach --pr` (PATH-shimmed gh resolving headRefName)
and `ws db-restore` (re-runs restore_command against the live DB fixture), plus
an optional HTTP-liveness check on the no-DB fixture. Remove stale comments in
test/smoke.sh describing the rebuild git-fetch and build_ctx/EXIT-trap bugs that
are already fixed in ws, and stop masking `ws rebuild` failures with `|| true`.
Update test/README.md to reflect smoke coverage of attach/db-restore.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**Open the PR** against the base branch:

```sh
gh pr create --base <pr-1-branch> \
  --title "Expand smoke + unit coverage: --pr, db-restore, app-serves; drop stale comments" \
  --body "$(cat <<'EOF'
## What
Test-only PR closing three smoke-coverage gaps and removing stale comments.

## Changes
- Smoke: new `ws attach --pr <n>` phase with a PATH-shimmed `gh` emitting canned
  `{"headRefName":"…"}`; asserts the resolved branch's worktree + active registry
  entry are created.
- Smoke: new `ws db-restore` step against the live DB fixture; asserts exit 0,
  app+db still running, registry unchanged.
- Smoke (optional / state whether done): no-DB fixture serves via busybox httpd
  and a host-side `curl` asserts a 200.
- Removed stale comments describing the rebuild git-fetch and build_ctx/EXIT-trap
  bugs — both already fixed in `ws` — and replaced `ws rebuild … || true` with a
  checked `|| fail`.
- README: note attach/db-restore are now smoke-covered.

## Out of scope
No engine (`ws`/`lib`) changes.

## Verification
- `bash -n` clean on all scripts
- `bats test/` green (59, or 60 with the optional --pr jq unit)
- `bash test/smoke.sh` exits 0 with the new PASS lines (Docker required)

Base: PR-1 branch (folds the P0 fixes onto generalize-boxwood). Depends on PR-1.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Overlap with PR-2

If PR-2 also edits the rebuild section of `test/smoke.sh` (e.g., to reduce two rebuilds to one, or to add a rebuild-failure assertion), there will be a merge conflict around lines 131-148 / 209-217. Coordinate: whichever of PR-2/PR-3 lands first removes the stale comments; the second rebases. The stale-comment removal (Change 0) is the natural seam — keep that change small and self-contained so it's easy to rebase. If PR-2 already removed the comments, drop Change 0 here and keep only the new coverage phases.
