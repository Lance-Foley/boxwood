#!/usr/bin/env bash
# Tier-2 smoke-integration harness for boxwood.
#
# Exercises the FULL session lifecycle (rebuild → attach/new → resume → restart
# → list → exec → end) against minimal alpine fixtures, in seconds, with no
# Rails and no big DB dump. Runs entirely headless via the engine's test seams:
#
#   WS_NO_ATTACH=1   `ws attach` returns instead of exec'ing into tmux
#   WS_ASSUME_YES=1  confirm() auto-answers yes (no interactive prompts)
#
# Two fixtures are driven:
#   test/smoke/fixture/    — no db   (has_db=false, no named volumes)
#   test/smoke/fixture-db/ — postgres (has_db=true, named pgdata volume)
#
# Prints a PASS/FAIL line per step and exits non-zero on the first failure.
set -euo pipefail

# ─── Locations ────────────────────────────────────────────────────────────────
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # test/
BOXWOOD_DIR="$(cd "$SMOKE_DIR/.." && pwd)"                  # repo root
WS="$BOXWOOD_DIR/ws"
FIXTURE_NODB="$SMOKE_DIR/smoke/fixture/.ws"
FIXTURE_DB="$SMOKE_DIR/smoke/fixture-db/.ws"

# ─── Isolated boxwood home + headless seams ─────────────────────────────────────
export WS_HOME="$(mktemp -d)"
export WS_NO_ATTACH=1
export WS_ASSUME_YES=1

# ─── Bookkeeping for cleanup ────────────────────────────────────────────────────
TMP_DIRS=("$WS_HOME")
PROJECTS=()           # compose projects to tear down (down -v)
IMAGES=(boxwood-smoke:latest boxwood-smoke-db:latest)

# ─── Output helpers ─────────────────────────────────────────────────────────────
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ─── Cleanup trap ───────────────────────────────────────────────────────────────
cleanup() {
  local rc=$?
  printf '\n\033[1;36m== cleanup\033[0m\n'
  local p
  for p in "${PROJECTS[@]:-}"; do
    [[ -z "$p" ]] && continue
    docker compose -p "$p" down -v >/dev/null 2>&1 || true
  done
  local img
  for img in "${IMAGES[@]}"; do
    docker image rm "$img" >/dev/null 2>&1 || true
  done
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  exit "$rc"
}
trap cleanup EXIT

# ─── Project-name derivation (must match the engine exactly) ────────────────────
# slugify mirrors ws: lowercase, non-alnum → '-', collapse, trim, cut 50.
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's|/|-|g; s/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50
}
project_name() {   # repo_dir_basename, branch  →  ws-<repo_slug>-<branch_slug>
  echo "ws-$(slugify "$1")-$(slugify "$2")"
}

# Build a throwaway, remote-less git repo seeded with a fixture .ws/ recipe.
# Echoes the repo path. $1 = fixture .ws dir, $2 = repo dir name.
make_repo() {
  local fixture_ws="$1" repo_name="$2"
  local parent repo
  parent="$(mktemp -d)"
  TMP_DIRS+=("$parent")
  repo="$parent/$repo_name"
  mkdir -p "$repo/.ws"
  cp -R "$fixture_ws/." "$repo/.ws/"
  git -C "$repo" init -q -b main 2>/dev/null \
    || { git -C "$repo" init -q && git -C "$repo" symbolic-ref HEAD refs/heads/main; }
  git -C "$repo" config user.email "smoke@boxwood.test"
  git -C "$repo" config user.name "boxwood smoke"
  : > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  # NO git remote — validates the remote-less hardening in attach/end.
  echo "$repo"
}

# Count active registry entries for a repo/branch.
active_count() {   # repo, branch
  jq --arg r "$1" --arg b "$2" \
    '[.[] | select(.repo == $r and .branch == $b and .status == "active")] | length' \
    "$WS_HOME/registry.json"
}
registry_status() {  # repo, branch  →  status string (e.g. active|ended)
  jq -r --arg r "$1" --arg b "$2" \
    '[.[] | select(.repo == $r and .branch == $b)] | last | .status // "missing"' \
    "$WS_HOME/registry.json"
}
# Containers (any state) in a compose project.
project_container_count() {  # project
  docker compose -p "$1" ps -a --format json 2>/dev/null | grep -c . || true
}
project_running_count() {    # project
  docker compose -p "$1" ps --status running --format json 2>/dev/null | grep -c . || true
}

# ════════════════════════════════════════════════════════════════════════════════
# Preconditions
# ════════════════════════════════════════════════════════════════════════════════
step "preconditions"
command -v docker >/dev/null || fail "docker not on PATH"
docker info >/dev/null 2>&1 || fail "Docker daemon not reachable (start OrbStack/Docker)"
[[ -x "$WS" ]] || fail "ws not executable at $WS"
[[ -d "$FIXTURE_NODB" ]] || fail "no-DB fixture missing at $FIXTURE_NODB"
[[ -d "$FIXTURE_DB" ]] || fail "with-DB fixture missing at $FIXTURE_DB"
pass "docker up, ws present, fixtures present (WS_HOME=$WS_HOME)"

# ════════════════════════════════════════════════════════════════════════════════
# Phase 1 — no-DB fixture: full lifecycle
# ════════════════════════════════════════════════════════════════════════════════
REPO_NAME="boxwood-smoke"
BRANCH="smoke-one"
REPO="$(make_repo "$FIXTURE_NODB" "$REPO_NAME")"
PROJECT="$(project_name "$REPO_NAME" "$BRANCH")"
PROJECTS+=("$PROJECT")

# ── (c) rebuild ─────────────────────────────────────────────────────────────────
# rebuild is run against a genuinely remote-less repo: `ws rebuild` guards its
# `git fetch origin` behind an origin check (and `|| true`), and `build_ctx` is a
# global cleaned by a guarded EXIT trap, so rebuild succeeds and exits 0 here.
step "(c) ws rebuild (no-DB) — builds boxwood-smoke:latest"
( cd "$REPO" && "$WS" rebuild ) || fail "ws rebuild (no-DB) failed"
docker image inspect boxwood-smoke:latest >/dev/null 2>&1 \
  || fail "boxwood-smoke:latest not present after rebuild"
pass "image boxwood-smoke:latest built (remote-less attach/end to follow)"

# ── (d) attach --new ─────────────────────────────────────────────────────────────
step "(d) ws attach --new \"smoke one\" — first run"
( cd "$REPO" && "$WS" attach --new "smoke one" ) || fail "attach --new failed"

WORKTREE="$WS_HOME/sessions/$REPO_NAME/$(slugify "$BRANCH")"
[[ -d "$WORKTREE" ]] || fail "worktree not created at $WORKTREE"
[[ "$(active_count "$REPO_NAME" "$BRANCH")" == "1" ]] \
  || fail "expected exactly 1 active registry entry, got $(active_count "$REPO_NAME" "$BRANCH")"
[[ "$(project_running_count "$PROJECT")" -ge 1 ]] \
  || fail "app container not running for project $PROJECT"
PORT="$(jq -r --arg r "$REPO_NAME" --arg b "$BRANCH" \
  '.[] | select(.repo==$r and .branch==$b and .status=="active") | .port' "$WS_HOME/registry.json" | head -1)"
[[ "$PORT" -ge 3100 && "$PORT" -le 3105 ]] || fail "assigned port $PORT outside 3100-3105"
pass "worktree + 1 active entry + container running on port $PORT (3100-3105)"

# ── (e) attach --branch (resume) ─────────────────────────────────────────────────
step "(e) ws attach --branch $BRANCH — resume (no duplicate)"
( cd "$REPO" && "$WS" attach --branch "$BRANCH" ) || fail "attach --branch (resume) failed"
[[ "$(active_count "$REPO_NAME" "$BRANCH")" == "1" ]] \
  || fail "resume created a duplicate: $(active_count "$REPO_NAME" "$BRANCH") active entries"
[[ "$(project_running_count "$PROJECT")" -ge 1 ]] || fail "container not running after resume"
pass "still exactly 1 active entry, container still running"

# ── (f) stop then attach (restart) ───────────────────────────────────────────────
step "(f) compose stop + ws attach --branch $BRANCH — restart from stopped"
docker compose -p "$PROJECT" stop >/dev/null 2>&1 || fail "compose stop failed"
[[ "$(project_running_count "$PROJECT")" -eq 0 ]] || fail "container still running after stop"
( cd "$REPO" && "$WS" attach --branch "$BRANCH" ) || fail "attach --branch (restart) failed"
[[ "$(project_running_count "$PROJECT")" -ge 1 ]] || fail "container not running after restart"
[[ "$(active_count "$REPO_NAME" "$BRANCH")" == "1" ]] || fail "restart altered active entry count"
pass "container restarted from stopped (no drop prompt — has_db=false, no volumes)"

# ── (g) list + exec ──────────────────────────────────────────────────────────────
step "(g) ws list + ws exec echo hi"
LIST_OUT="$( cd "$REPO" && "$WS" list 2>&1 )" || fail "ws list failed"
echo "$LIST_OUT" | grep -q "$BRANCH" || fail "session '$BRANCH' not shown in ws list"
EXEC_OUT="$( cd "$WORKTREE" && "$WS" exec echo hi 2>&1 )" || fail "ws exec failed"
echo "$EXEC_OUT" | grep -q "hi" || fail "ws exec output missing 'hi' (got: $EXEC_OUT)"
pass "session listed; exec returned 'hi'"

# ── (h) end ──────────────────────────────────────────────────────────────────────
step "(h) ws end --branch $BRANCH --no-push — teardown"
# --no-push: smoke repos are remote-less, and under WS_ASSUME_YES the push prompt
# now auto-NOs anyway; pass it explicitly so teardown never tries to publish.
( cd "$REPO" && "$WS" end --branch "$BRANCH" --no-push ) || fail "ws end failed"
[[ "$(project_container_count "$PROJECT")" -eq 0 ]] \
  || fail "compose project $PROJECT still has containers after end"
[[ ! -d "$WORKTREE" ]] || fail "worktree dir still present after end: $WORKTREE"
[[ "$(registry_status "$REPO_NAME" "$BRANCH")" == "ended" ]] \
  || fail "registry status not 'ended' (got: $(registry_status "$REPO_NAME" "$BRANCH"))"
pass "no containers, worktree gone, registry entry 'ended'"

# ── (j) attach --pr — gh branch resolution ──────────────────────────────────────
# Covers the only path that shells out to `gh`: `cmd_attach` resolves a PR number
# to a branch via `gh pr view <n> --json headRefName | jq -r '.headRefName'`, then
# attaches that branch. A PATH-prepended `gh` stub feeds canned JSON; because the
# harness invokes the engine via its absolute path ("$WS"), the stub only shadows
# the `gh` that `ws` itself spawns — exactly the seam we want.
step "(j) ws attach --pr 7 — resolves headRefName via gh, then attaches"
PR_REPO_NAME="boxwood-smoke-pr"
PR_BRANCH="pr-seven"
PR_REPO="$(make_repo "$FIXTURE_NODB" "$PR_REPO_NAME")"
PR_PROJECT="$(project_name "$PR_REPO_NAME" "$PR_BRANCH")"
PROJECTS+=("$PR_PROJECT")

# This fixture pins image.name to boxwood-smoke:latest, built in phase 1. `ws end`
# removes containers/volumes but NOT the base image, so it survives; rebuild only
# if it somehow doesn't.
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
[[ -d "$PR_WORKTREE" ]] \
  || fail "attach --pr did not create worktree for resolved branch $PR_BRANCH"
[[ "$(active_count "$PR_REPO_NAME" "$PR_BRANCH")" == "1" ]] \
  || fail "attach --pr: expected 1 active entry for $PR_BRANCH, got $(active_count "$PR_REPO_NAME" "$PR_BRANCH")"
# The PR number should be recorded on the registry entry (first-run path passes
# pr_number through to registry_add as a JSON number; `jq -r` prints it as 7).
[[ "$(jq -r --arg r "$PR_REPO_NAME" --arg b "$PR_BRANCH" \
   '.[] | select(.repo==$r and .branch==$b and .status=="active") | .pr' "$WS_HOME/registry.json" | head -1)" == "7" ]] \
  || fail "attach --pr: registry .pr not 7"
pass "gh resolved PR #7 → $PR_BRANCH; worktree + active entry created, pr=7 recorded"

( cd "$PR_REPO" && "$WS" end --branch "$PR_BRANCH" --no-push ) || fail "attach --pr cleanup end failed"
[[ "$(project_container_count "$PR_PROJECT")" -eq 0 ]] \
  || fail "attach --pr cleanup: project $PR_PROJECT still has containers after end"
[[ "$(registry_status "$PR_REPO_NAME" "$PR_BRANCH")" == "ended" ]] \
  || fail "attach --pr cleanup: registry status not 'ended'"
pass "attach --pr session torn down (no containers, entry 'ended')"

# ════════════════════════════════════════════════════════════════════════════════
# Phase 2 — with-DB fixture: minimal first_run + end
# ════════════════════════════════════════════════════════════════════════════════
DB_REPO_NAME="boxwood-smoke-db"
DB_BRANCH="smoke-db"
DB_REPO="$(make_repo "$FIXTURE_DB" "$DB_REPO_NAME")"
DB_PROJECT="$(project_name "$DB_REPO_NAME" "$DB_BRANCH")"
PROJECTS+=("$DB_PROJECT")

step "(i) with-DB: rebuild + attach --new + end (has_db + pgdata volume + db-init wait)"
( cd "$DB_REPO" && "$WS" rebuild ) || fail "ws rebuild (with-DB) failed"
docker image inspect boxwood-smoke-db:latest >/dev/null 2>&1 \
  || fail "boxwood-smoke-db:latest not present after rebuild"

( cd "$DB_REPO" && "$WS" attach --new "smoke db" ) || fail "with-DB attach --new failed"
DB_WORKTREE="$WS_HOME/sessions/$DB_REPO_NAME/$(slugify "$DB_BRANCH")"
[[ -d "$DB_WORKTREE" ]] || fail "with-DB worktree not created"
[[ "$(active_count "$DB_REPO_NAME" "$DB_BRANCH")" == "1" ]] \
  || fail "with-DB: expected 1 active entry, got $(active_count "$DB_REPO_NAME" "$DB_BRANCH")"
# Both app AND db services must be running. The app only reaches a healthy
# first_run state if db-init.sh's `until pg_isready -h db` wait loop completed
# (the entrypoint blocks on db-init before exec'ing the CMD, and the healthcheck
# marker is only written by db-init). So a running app == the db-init wait
# succeeded. NOTE: `ws` resets DB_INIT=false and recreates the app container after
# first_run, which wipes the ephemeral /tmp marker — hence we assert on the
# durable running/healthy state and the named volume, not the marker.
[[ "$(project_running_count "$DB_PROJECT")" -ge 2 ]] \
  || fail "with-DB: expected app+db running, got $(project_running_count "$DB_PROJECT")"
docker compose -p "$DB_PROJECT" ps --status running --services 2>/dev/null | grep -qx db \
  || fail "with-DB: db service not running"
docker compose -p "$DB_PROJECT" ps --status running --services 2>/dev/null | grep -qx app \
  || fail "with-DB: app service not running (db-init wait loop would have blocked first_run)"
# Named pgdata volume must exist (drives project_has_volumes detection).
docker volume ls -q --filter "name=^${DB_PROJECT}_" | grep -q . \
  || fail "with-DB: no named volume for $DB_PROJECT (pgdata not created)"
pass "with-DB first_run: app+db healthy (db-init wait completed), pgdata volume present"

# ── (k) db-restore --yes — re-run the repo's DB setup against the live session ───
# db-init.sh keeps a durable run counter at /app/.db_init_count, and /app is the
# bind-mounted worktree, so the counter is readable here on the host and survives
# the app-container recreation after first_run. first_run ran db-init once → "1".
# A successful `ws db-restore` must re-run db-init and bump it to "2": we assert
# the counter ACTUALLY changed (not just exit 0), per the spec's "don't trust the
# exit code" requirement. --yes is required: without it db-restore auto-NOs under
# WS_ASSUME_YES (DESTRUCTIVE confirm, default N) and no-ops.
step "(k) ws db-restore --yes --branch $DB_BRANCH — re-runs restore_command in the app container"
DB_COUNT_FILE="$DB_WORKTREE/.db_init_count"
[[ "$(cat "$DB_COUNT_FILE" 2>/dev/null || echo 0)" == "1" ]] \
  || fail "db-restore precondition: expected db-init run counter 1 after first_run, got $(cat "$DB_COUNT_FILE" 2>/dev/null || echo 0)"
RESTORE_OUT="$( cd "$DB_REPO" && "$WS" db-restore --yes --branch "$DB_BRANCH" 2>&1 )" \
  || fail "ws db-restore --yes failed (exit non-zero): $RESTORE_OUT"
# db-init's observable stdout proves it ran inside the container.
echo "$RESTORE_OUT" | grep -q 'ready (db-init run #2)' \
  || fail "db-restore: db-init did not re-run (missing 'ready (db-init run #2)' in output: $RESTORE_OUT)"
# Durable counter must have advanced 1 → 2 (restore actually re-ran db-init).
[[ "$(cat "$DB_COUNT_FILE" 2>/dev/null || echo 0)" == "2" ]] \
  || fail "db-restore: run counter did not advance to 2 (got $(cat "$DB_COUNT_FILE" 2>/dev/null || echo 0)); restore did not actually run"
# Restore must not tear anything down: app+db still running, registry unchanged.
[[ "$(project_running_count "$DB_PROJECT")" -ge 2 ]] \
  || fail "db-restore: app+db not both running afterward, got $(project_running_count "$DB_PROJECT")"
[[ "$(active_count "$DB_REPO_NAME" "$DB_BRANCH")" == "1" ]] \
  || fail "db-restore altered the active entry count (got $(active_count "$DB_REPO_NAME" "$DB_BRANCH"))"
pass "db-restore re-ran db-init (counter 1→2, 'ready' emitted); app+db still running, registry unchanged"

( cd "$DB_REPO" && "$WS" end --branch "$DB_BRANCH" --no-push ) || fail "with-DB end failed"
[[ "$(project_container_count "$DB_PROJECT")" -eq 0 ]] || fail "with-DB project still has containers"
[[ ! -d "$DB_WORKTREE" ]] || fail "with-DB worktree still present after end"
[[ "$(registry_status "$DB_REPO_NAME" "$DB_BRANCH")" == "ended" ]] \
  || fail "with-DB registry status not 'ended'"
docker volume ls -q --filter "name=^${DB_PROJECT}_" | grep -q . \
  && fail "with-DB: named volume survived 'ws end' (down -v should remove it)" || true
pass "with-DB teardown: no containers, no volumes, worktree gone, entry 'ended'"

step "ALL SMOKE STEPS PASSED"
