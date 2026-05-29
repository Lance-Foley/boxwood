# PR-2: Serialize port allocation + registry write under a lock

**Priority:** P1 · **Effort:** ~1–2 hrs · **Scope:** `ws` (the Orchestrator) + one new bats test · **Base branch:** `generalize-boxwood` (PR-1's branch) · **Depends-on:** PR-1 (the P0 foundation must land first; if PR-1 has already merged to `main`, branch off `main` instead).

---

## Problem

Port allocation is a **check-then-act race with no locking**. `next_port()` reads the Registry, returns the lowest free host port, and the caller registers it *later* — after the entire Compose stack has been brought up. Two concurrent `ws attach` runs read the same Registry snapshot, pick the **same** host port, and the second stack fails to bind. Host ports are machine-global, so this bites **across repos**, not just within one — which is precisely boxwood's core use case (multiple Projects / agent fan-out attaching at once).

### Verified current code (commit `6a41dd5`, branch `generalize-boxwood`)

**`next_port()` — `ws` lines 62–74** (reads the Registry, returns lowest free port, no lock):

```bash
# Lowest unused host port in this repo's configured range. Used ports are taken
# across ALL repos (host ports are machine-global).
next_port() {
  local lo hi used
  lo=$(cfg_default '.ports.range[0]' 3000)
  hi=$(cfg_default '.ports.range[1]' 3005)
  used=$(jq -r '.[] | select(.status == "active") | .port' "$REGISTRY")
  for p in $(seq "$lo" "$hi"); do
    if ! echo "$used" | grep -qw "$p"; then echo "$p"; return 0; fi
  done
  error "All session ports ($lo-$hi) are in use. Run 'ws end' to free one."
  return 1
}
```

**`registry_add()` — `ws` lines 35–43** (atomic temp-file + `mv` write; this atomicity must be preserved):

```bash
registry_add() {
  local repo="$1" branch="$2" project="$3" port="$4" path="$5" pr="${6:-null}"
  local now tmp
  now=$(date +"%Y-%m-%d %H:%M"); tmp=$(mktemp)
  jq --arg r "$repo" ... \
     '. + [{repo:$r, branch:$b, project:$pj, port:$p, path:$pt, pr:$pr, started:$s, status:"active"}]' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}
```

**The race window — `cmd_attach`, new-session path, `ws` lines 419–423:**

```bash
  local port; port=$(next_port) || exit 1          # 419  ← allocate (reads Registry)
                                                    #
  setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"   # 421
  compose_up "$project" "$worktree_path" "$port" "first_run"           # 422  ← LONG: --wait
  registry_add "$REPO" "$branch" "$project" "$port" ...                # 423  ← register (writes Registry)
```

The window between line 419 (allocate) and line 423 (register) spans `compose_up`, which calls
`docker compose ... up -d --wait --wait-timeout 600` (verified at **`lib/docker.sh` line 86**). So the
allocated port is **invisible to a second `ws attach`** for *up to 600 seconds*. The second run reads the
same snapshot, picks the same port, and its Compose stack fails to bind — only **after** burning the full
healthcheck wait, then erroring with "Containers did not become healthy in time."

**Resume path has the same window — `cmd_attach`, `ws` lines 349–373:**

```bash
    local port
    port=$(jq ... | head -1)                        # existing port, else:
    if [[ -z "$port" || "$port" == "null" ]]; then port=$(next_port) || exit 1; fi   # 351 ← allocate
    ...
    compose_up "$project" "$worktree_path" "$port" "$state"            # 368 ← LONG
    ...
    [[ -z "$in_registry" ]] && registry_add ... "$port" ...           # 373 ← register
```

### Why it matters / real-world bite

- Two agents (or two terminals) running `ws attach` near-simultaneously across different repos collide on the same host port.
- The collision is **not** detected at allocation time. It surfaces only after the loser's stack times out on `--wait` (up to 10 minutes), producing a confusing "not healthy" error rather than "port in use."
- There is currently **no lock logic anywhere** in `ws` or `lib/*.sh` (verified by grep). This is a clean greenfield add, not a modification of existing locking.

---

## Required changes

Serialize the **allocate → register** window under a single global mutex on `$WS_HOME/registry.lock`.
Use a **portable `mkdir`-based lock** (macOS ships no util-linux `flock` by default; `mkdir` is atomic on
all POSIX filesystems, has no extra dependency, and is `set -e` safe). Preserve the existing atomic
temp-file + `mv` Registry writes inside the locked section.

### 1. Add lock helpers near the top of `ws` (after the `REGISTRY=...` block, around line 21–24)

Define the lock path next to the other home paths and add `acquire_lock` / `release_lock`:

```bash
REGISTRY="$WS_HOME/registry.json"
REGISTRY_LOCK="$WS_HOME/registry.lock"
```

```bash
# ─── Registry mutex ─────────────────────────────────────────────────────────
# Portable, dependency-free mutex around the allocate→register window. mkdir is
# atomic on every POSIX filesystem (no util-linux `flock`, which macOS lacks).
# The lock MUST be released on every exit path — see the EXIT trap in
# with_registry_lock. Stale locks (from a killed process) are reaped after a
# generous timeout so a crash can never wedge the tool permanently.
WS_LOCK_TIMEOUT="${WS_LOCK_TIMEOUT:-30}"   # seconds to wait before giving up
WS_LOCK_STALE="${WS_LOCK_STALE:-120}"      # seconds before a held lock is deemed stale

acquire_lock() {
  local waited=0
  until mkdir "$REGISTRY_LOCK" 2>/dev/null; do
    # Reap a stale lock left by a crashed process.
    if [[ -d "$REGISTRY_LOCK" ]]; then
      local age now mtime
      now=$(date +%s)
      mtime=$(stat -f %m "$REGISTRY_LOCK" 2>/dev/null || stat -c %Y "$REGISTRY_LOCK" 2>/dev/null || echo "$now")
      age=$(( now - mtime ))
      if (( age > WS_LOCK_STALE )); then
        warn "Removing stale registry lock (held ${age}s)."
        rm -rf "$REGISTRY_LOCK"
        continue
      fi
    fi
    if (( waited >= WS_LOCK_TIMEOUT )); then
      error "Could not acquire registry lock after ${WS_LOCK_TIMEOUT}s (another 'ws' may be busy)."
      return 1
    fi
    sleep 1; waited=$(( waited + 1 ))
  done
  return 0
}

release_lock() {
  rm -rf "$REGISTRY_LOCK" 2>/dev/null || true
}
```

> Note on `stat`: macOS uses `stat -f %m`, GNU/Linux uses `stat -c %Y` — the `||` chain handles both,
> mirroring the existing `date -v-30d ... || date -d ...` portability pattern already in `registry_prune`
> (`ws` line 55).

### 2. Add a `with_registry_lock` wrapper that guarantees release on every exit path

The lock **must** be released on success, on error, and on `exit`/signal. Wrap the critical region so a
single trap covers all paths:

```bash
# Run a command holding the registry lock; always release it (success, error,
# or interrupt). Usage: with_registry_lock <fn> [args...]
with_registry_lock() {
  acquire_lock || return 1
  # Release on any way out of this subshell-free scope.
  trap 'release_lock' RETURN
  "$@"
  local rc=$?
  trap - RETURN
  release_lock
  return $rc
}
```

> Implementation latitude: `trap ... RETURN` inside a function is the cleanest guarantee. If the
> implementer prefers, an explicit `acquire_lock; "$@"; rc=$?; release_lock; return $rc` with an
> additional `trap 'release_lock' EXIT INT TERM` set in `cmd_attach` is acceptable **as long as the
> acceptance test proves the lock is released on the error path** (see Acceptance criteria). The
> non-negotiable requirement is: the lock is released on **all** exit paths.

### 3. Provide a single locked "allocate-and-register" primitive and use it in `cmd_attach`

The point of the lock is to make **allocate + register atomic** so the chosen port is visible to any
other `ws` before this one releases. `compose_up` is the slow part and must **not** be inside the lock
(holding the mutex for 10 minutes would serialize every attach machine-wide). The fix is to **register
the port up front, under the lock**, then bring the stack up:

Add a helper:

```bash
# Atomically pick the lowest free port AND record the session, so a concurrent
# 'ws attach' sees the port as taken before we release. Echoes the chosen port.
allocate_and_register() {
  local repo="$1" branch="$2" project="$3" path="$4" pr="${5:-null}"
  local port
  port=$(next_port) || return 1
  registry_add "$repo" "$branch" "$project" "$port" "$path" "$pr"
  echo "$port"
}
```

Then in the **new-session path** (`ws` lines 419–423) replace the split allocate/register with a single
locked call, and move `registry_add` out of the post-`compose_up` position:

```bash
  local port
  port=$(with_registry_lock allocate_and_register \
           "$REPO" "$branch" "$project" "$worktree_path" "${pr_number:-null}") || exit 1

  setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"
  compose_up "$project" "$worktree_path" "$port" "first_run"
  # (registry_add removed from here — already done under the lock above)
```

For the **resume path** (`ws` lines 349–373): only allocate a *new* port when the session has none
(`port` empty/null). Keep the existing-port reuse as-is, but wrap the fallback allocation +
its `registry_add` in the lock. Concretely, when `next_port()` is the source of the port, register it
under the lock at that point rather than at line 373:

```bash
    local port
    port=$(jq -r --arg r "$REPO" --arg b "$branch" '...' "$REGISTRY" | head -1)
    if [[ -z "$port" || "$port" == "null" ]]; then
      port=$(with_registry_lock allocate_and_register \
               "$REPO" "$branch" "$project" "$worktree_path" "${pr_number:-null}") || exit 1
    fi
```

…and drop the trailing `[[ -z "$in_registry" ]] && registry_add ...` line (373) for the
newly-allocated case, since `allocate_and_register` already wrote the entry. **Care:** the resume path
also re-runs when a registry entry exists but a port was already assigned — preserve that "reuse existing
port, don't double-register" behavior. The `in_registry` check exists today precisely to avoid duplicate
entries; keep an equivalent guard so a resume of an already-registered session does not append a second row.

> If reworking the resume path cleanly proves fiddly, a minimal acceptable alternative is to leave the
> resume path's port reuse untouched and only wrap the `next_port` fallback + its registration under the
> lock. The mandatory outcome: **no two concurrent allocations ever return the same port**, proven by the
> bats test below.

### 4. Add a bats test proving two rapid allocations get DISTINCT ports

Add to `test/unit.bats` (under a new `# ─── allocate_and_register / locking ───` section). The test seeds
the Registry, then performs two locked allocate-and-registers and asserts the ports differ and both are
recorded:

```bash
@test "allocate_and_register: two sequential locked allocations get distinct ports" {
  export CONFIG_JSON='{"ports":{"range":[3000,3005]}}'
  echo '[]' > "$REGISTRY"

  p1=$(with_registry_lock allocate_and_register "r" "a" "p-a" "/a" null)
  p2=$(with_registry_lock allocate_and_register "r" "b" "p-b" "/b" null)

  [ "$p1" = "3000" ]
  [ "$p2" = "3001" ]
  [ "$p1" != "$p2" ]
  [ "$(jq 'length' "$REGISTRY")" -eq 2 ]
  [ "$(jq -r '[.[].port] | sort | join(",")' "$REGISTRY")" = "3000,3001" ]
}

@test "with_registry_lock: releases the lock on success" {
  echo '[]' > "$REGISTRY"
  with_registry_lock true
  [ ! -d "$REGISTRY_LOCK" ]
}

@test "with_registry_lock: releases the lock even when the body fails" {
  echo '[]' > "$REGISTRY"
  run with_registry_lock false
  [ "$status" -ne 0 ]
  [ ! -d "$REGISTRY_LOCK" ]
}

@test "acquire_lock: second acquire blocks then reaps a stale lock" {
  # Simulate a crashed holder: lock dir exists but is old.
  mkdir -p "$REGISTRY_LOCK"
  # Backdate it well past the stale threshold.
  touch -t 200001010000 "$REGISTRY_LOCK" 2>/dev/null || true
  export WS_LOCK_STALE=1 WS_LOCK_TIMEOUT=5
  run acquire_lock
  [ "$status" -eq 0 ]
  release_lock
}
```

> The "distinct ports" test is the load-bearing one required by the spec. It proves the allocate→register
> atomicity: because the first allocation **registers** 3000 before the second runs, the second sees 3000
> as taken and returns 3001 — which is exactly the property the lock guarantees under concurrency.
> A true concurrency test (two background subshells racing) is flaky in CI and not required; sequential
> allocate-and-register exercising the same locked primitive is the agreed verification.

---

## Out of scope / do NOT touch

- **`lib/docker.sh` `compose_up`** — do NOT move `compose_up` inside the lock (it would serialize every
  attach for up to 10 minutes machine-wide). The `--wait --wait-timeout 600` behavior stays as-is.
- The temp-file + `mv` atomicity inside `registry_add`, `registry_end`, `registry_prune` — keep it.
  Do not switch to in-place `jq` edits.
- `next_port()`'s selection logic (lowest-free-in-range) — unchanged; only its *call site* is now wrapped.
- The already-fixed work from PR-1: `build_ctx` EXIT trap (`ws` lines 579–590), the `gh`/`origin`
  hardening in `cmd_attach`/`cmd_rebuild`, the main-guard, `yq` config parsing — do NOT revisit.
- Do NOT add a `flock` dependency or a new Homebrew formula. `mkdir` is intentionally dependency-free.
  (You MAY mention `flock` in a code comment as an alternative, but the implementation must be `mkdir`.)
- The smoke test (`test/smoke.sh`) — no new scenarios required for this PR.

---

## Acceptance criteria

- [ ] `$WS_HOME/registry.lock` is acquired before, and released after, every port allocate-and-register.
- [ ] `next_port()` and `registry_add()` for a **newly allocated** port happen atomically under the lock
      (a concurrent `ws attach` sees the port as taken before the first releases).
- [ ] `compose_up` runs **outside** the lock.
- [ ] The lock is released on success, on error (non-zero body), and on `exit`/interrupt (trap).
- [ ] Stale locks (older than `WS_LOCK_STALE`, default 120s) are reaped so a crash cannot wedge `ws`.
- [ ] `registry_add`/`registry_end`/`registry_prune` still use atomic temp-file + `mv`.
- [ ] New bats test "two sequential locked allocations get distinct ports" passes, plus the lock
      release-on-success and release-on-failure tests.
- [ ] Existing 59 bats tests still pass (now 63+ with the new ones).
- [ ] `bash -n` is clean on `ws` and every `lib/*.sh`.

---

## Verification

Run from the repo root (`/Users/lancefoley/code/boxwood`):

```bash
# 1. Syntax check every script.
bash -n ws && for f in lib/*.sh; do bash -n "$f"; done && echo "syntax OK"
```
Expected: `syntax OK` (no other output).

```bash
# 2. Full bats suite (requires `bats` + `jq`; `yq` for config.bats).
bats test/
```
Expected: all tests pass — **63 or more** (59 existing + the 4 new lock tests). Look for
`ok N allocate_and_register: two sequential locked allocations get distinct ports`,
`ok N with_registry_lock: releases the lock on success`,
`ok N with_registry_lock: releases the lock even when the body fails`, and
`ok N acquire_lock: second acquire blocks then reaps a stale lock`.

```bash
# 3. Smoke test — full alpine session lifecycle (needs Docker running).
bash test/smoke.sh
```
Expected: lifecycle completes (attach → containers healthy → end) with no regression. Skip only if
Docker is not available in the runner; note that in the PR body if so.

---

## PR steps

**Branch name:** `port-allocation-lock` (off `generalize-boxwood`; if PR-1 already merged, off `main`).

```bash
git checkout generalize-boxwood && git pull
git checkout -b port-allocation-lock
# ...implement changes in `ws` + `test/unit.bats`...
bash -n ws && for f in lib/*.sh; do bash -n "$f"; done
bats test/
git add ws test/unit.bats
git commit
```

**Commit message guidance** (subject + body; the body MUST end with the Co-Authored-By line):

```
Serialize port allocation + registry write under a lock

next_port() read the Registry and the caller registered the chosen port
only after compose_up's healthcheck wait (up to 600s), leaving a long
check-then-act window. Two concurrent `ws attach` runs picked the same
machine-global host port; the loser failed to bind and burned the full
--wait timeout before erroring.

Add a portable, dependency-free mkdir-based mutex on
$WS_HOME/registry.lock and an allocate_and_register primitive so port
selection and registration happen atomically under the lock; compose_up
stays outside the lock. The lock is released on every exit path (trap)
and stale locks are reaped after a timeout. Adds bats coverage proving
two rapid allocations get distinct ports and the lock is always released.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**Open the PR** (base = PR-1's branch, or `main` if PR-1 merged):

```bash
gh pr create --base generalize-boxwood --head port-allocation-lock \
  --title "Serialize port allocation + registry write under a lock"
```

**PR body outline:**

- **Problem** — check-then-act race in `next_port()` → `registry_add()`; window spans `compose_up`'s
  `--wait --wait-timeout 600`; host ports are machine-global so it bites across repos (agent fan-out).
- **Fix** — `mkdir`-based mutex on `$WS_HOME/registry.lock`; `allocate_and_register` runs
  `next_port` + `registry_add` atomically under the lock; `compose_up` stays outside; lock released on
  all paths via trap; stale-lock reaping.
- **Why `mkdir` and not `flock`** — macOS ships no util-linux `flock`; `mkdir` is atomic and
  dependency-free.
- **Testing** — `bash -n` clean; `bats test/` (now 63+); smoke test green (or noted as skipped if no Docker).
- **Depends on** — PR-1 (foundation). Base branch: `generalize-boxwood`.

Last line of the PR body:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
