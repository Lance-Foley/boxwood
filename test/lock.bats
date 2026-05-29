#!/usr/bin/env bats
# Tier-1 unit tests for boxwood's registry mutex (PR-2).
#
# These exercise the mkdir-based lock primitives (acquire_lock, release_lock,
# with_registry_lock) and the allocate_and_register / register_if_absent
# primitives by sourcing the (main-guarded) `ws` script. No Docker required.
#
# The lock serializes every registry read-modify-write: port allocation +
# registration, register_if_absent, registry_end, and registry_prune. compose_up
# stays OUTSIDE the lock (it can wait up to 600s) — that is verified by reading
# the code, not here.

load 'helper'

setup() {
  load_ws
}

# ─── allocate_and_register ordering ─────────────────────────────────────────
# NOTE: this proves the allocate→register window is ATOMIC (the chosen port is
# recorded before the next allocation runs, so the second sees it as taken and
# returns the next port). It does NOT prove mutual exclusion of two concurrent
# holders — that is covered by the dedicated acquire/timeout test below.

@test "allocate_and_register: sequential locked allocations register before the next, yielding distinct ports" {
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

@test "allocate_and_register: propagates next_port failure (range exhausted)" {
  export CONFIG_JSON='{"ports":{"range":[3000,3000]}}'
  cat > "$REGISTRY" <<'JSON'
[{"status":"active","port":3000}]
JSON
  run with_registry_lock allocate_and_register "r" "a" "p-a" "/a" null
  [ "$status" -ne 0 ]
  # No partial row appended on failure.
  [ "$(jq 'length' "$REGISTRY")" -eq 1 ]
  # And the lock is released even though the body failed.
  [ ! -d "$REGISTRY_LOCK" ]
}

# ─── register_if_absent (resume-path primitive) ─────────────────────────────

@test "register_if_absent: appends when no active row exists" {
  echo '[]' > "$REGISTRY"
  with_registry_lock register_if_absent "r" "a" "p-a" 3000 "/a" null
  [ "$(jq 'length' "$REGISTRY")" -eq 1 ]
  [ "$(jq -r '.[0].port' "$REGISTRY")" = "3000" ]
}

@test "register_if_absent: no-op when an active row already exists (no duplicate)" {
  echo '[]' > "$REGISTRY"
  registry_add "r" "a" "p-a" 3000 "/a"
  with_registry_lock register_if_absent "r" "a" "p-a" 3000 "/a" null
  [ "$(jq 'length' "$REGISTRY")" -eq 1 ]
}

# ─── with_registry_lock release guarantees ──────────────────────────────────

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

@test "with_registry_lock: forwards the body's exit code" {
  run with_registry_lock bash -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "with_registry_lock: does not clobber a caller's pre-existing EXIT trap" {
  marker="$WS_HOME/exit-marker"
  rm -f "$marker"
  # Run in a child bash so its EXIT trap actually fires on process exit.
  # with_registry_lock must NOT touch traps, so the caller's EXIT trap survives.
  run bash -c '
    set -euo pipefail
    source "'"$WS_BIN"'"
    trap "echo fired > \"'"$marker"'\"" EXIT
    with_registry_lock true
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "fired" ]
}

# ─── genuine mutual exclusion ───────────────────────────────────────────────
# This is the test that FAILS if acquire_lock were a no-op: a second acquire
# while the lock is held must block and then time out (nonzero); after release,
# acquisition must succeed.

@test "acquire_lock: a second acquire while held blocks then times out, succeeds after release" {
  # Keep the lock from being reaped during the timeout window.
  export WS_LOCK_STALE=3600 WS_LOCK_TIMEOUT=1

  # First holder takes the lock.
  acquire_lock
  [ -d "$REGISTRY_LOCK" ]

  # Second acquire cannot get it — it waits WS_LOCK_TIMEOUT then fails nonzero.
  run acquire_lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not acquire registry lock"* ]]

  # After release, the lock is free and a fresh acquire succeeds.
  release_lock
  [ ! -d "$REGISTRY_LOCK" ]
  run acquire_lock
  [ "$status" -eq 0 ]
  release_lock
}

# ─── stale-lock reaping ─────────────────────────────────────────────────────

@test "acquire_lock: reaps a stale lock left by a crashed holder" {
  # Simulate a crashed holder: lock dir exists but is old.
  mkdir -p "$REGISTRY_LOCK"
  # Backdate it well past the stale threshold (epoch 0 era).
  touch -t 200001010000 "$REGISTRY_LOCK" 2>/dev/null || true
  export WS_LOCK_STALE=1 WS_LOCK_TIMEOUT=5

  run acquire_lock
  [ "$status" -eq 0 ]
  # We now hold the (reaped-and-recreated) lock; it records our PID.
  [ -d "$REGISTRY_LOCK" ]
  release_lock
  [ ! -d "$REGISTRY_LOCK" ]
}

@test "acquire_lock: does NOT reap a fresh lock (waits, then times out)" {
  # A just-created lock is not stale; acquire must time out rather than reap it.
  mkdir -p "$REGISTRY_LOCK"            # fresh mtime = now
  export WS_LOCK_STALE=3600 WS_LOCK_TIMEOUT=1
  run acquire_lock
  [ "$status" -ne 0 ]
  # The fresh lock was left intact (not reaped).
  [ -d "$REGISTRY_LOCK" ]
  rm -rf "$REGISTRY_LOCK"
}

# ─── release_lock safety ────────────────────────────────────────────────────

@test "release_lock: is idempotent (no error when already released)" {
  echo '[]' > "$REGISTRY"
  acquire_lock
  release_lock
  release_lock   # second call must be a clean no-op
  [ ! -d "$REGISTRY_LOCK" ]
}

@test "release_lock: refuses to remove a lock owned by another process" {
  # Lock owned by a different (fake) PID — release_lock must leave it alone so a
  # stray trap can never delete the lock another `ws` is actively holding.
  mkdir -p "$REGISTRY_LOCK"
  echo "999999" > "$REGISTRY_LOCK/pid"   # not our $$
  release_lock
  [ -d "$REGISTRY_LOCK" ]
  rm -rf "$REGISTRY_LOCK"
}
