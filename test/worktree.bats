#!/usr/bin/env bats
# Tier-1 unit tests for boxwood's git-worktree provisioning helpers.
#
# Unlike the docker-backed helpers (stubbed via PATH), these run against REAL
# throwaway git repos created per-test — `git` is a hard dependency anyway, and
# the whole point of extracting `resolve_base_ref` / `ensure_worktree` is that
# the worktree-recovery edge cases (detached HEAD, orphaned dir, branch checked
# out elsewhere, remoteless base-ref) become fast, daemon-free units instead of
# only being reachable through the full Docker smoke lifecycle.

load 'helper'

setup() {
  load_ws
  FIX="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/wtfix.XXXXXX")"
}

# Create a git repo at $1 with an initial commit on branch $2 (default "main").
make_repo() {
  local root="$1" main="${2:-main}"
  git init -q -b "$main" "$root"
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name  t
  echo seed > "$root/README"
  git -C "$root" add -A
  git -C "$root" commit -qm init
}

# ─── resolve_base_ref ─────────────────────────────────────────────────────────

@test "resolve_base_ref: prefers origin/<main> when an origin remote exists" {
  make_repo "$FIX/origin" main
  git clone -q "$FIX/origin" "$FIX/work"
  git -C "$FIX/work" config user.email t@t.t
  git -C "$FIX/work" config user.name  t

  run resolve_base_ref "$FIX/work" main
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main" ]
}

@test "resolve_base_ref: falls back to local <main> when there is no origin" {
  make_repo "$FIX/solo" main

  run resolve_base_ref "$FIX/solo" main
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "resolve_base_ref: falls back to HEAD when neither origin/<main> nor local <main> exist" {
  make_repo "$FIX/solo" main   # real branch is 'main', no 'trunk', no origin

  run resolve_base_ref "$FIX/solo" trunk
  [ "$status" -eq 0 ]
  [ "$output" = "HEAD" ]
}

# ─── ensure_worktree ──────────────────────────────────────────────────────────
#
# Invariant under test: on success, a worktree exists at <path> checked out on
# <branch>. base_ref present → new-branch mode; absent → existing-branch mode.

head_branch() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null; }

@test "ensure_worktree: creates a worktree for an existing branch (no base_ref)" {
  make_repo "$FIX/repo" main
  git -C "$FIX/repo" branch feat
  local wt="$FIX/wt"

  run ensure_worktree "$FIX/repo" "$wt" feat
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  [ "$(head_branch "$wt")" = "feat" ]
}

@test "ensure_worktree: creates a NEW branch from base_ref when one is given" {
  make_repo "$FIX/repo" main
  local wt="$FIX/wt"

  run ensure_worktree "$FIX/repo" "$wt" newfeat main
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "newfeat" ]
  # The branch now exists in the main repo too.
  git -C "$FIX/repo" rev-parse --verify --quiet newfeat
}

@test "ensure_worktree: is a no-op when a valid worktree is already on the branch" {
  make_repo "$FIX/repo" main
  git -C "$FIX/repo" branch feat
  local wt="$FIX/wt"
  git -C "$FIX/repo" worktree add -q "$wt" feat

  run ensure_worktree "$FIX/repo" "$wt" feat
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "feat" ]
}

@test "ensure_worktree: recovers a worktree stuck in detached HEAD back to the branch" {
  make_repo "$FIX/repo" main
  git -C "$FIX/repo" branch feat
  local wt="$FIX/wt"
  git -C "$FIX/repo" worktree add -q "$wt" feat
  git -C "$wt" checkout -q --detach

  run ensure_worktree "$FIX/repo" "$wt" feat
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "feat" ]
}

@test "ensure_worktree: recovers detached HEAD via origin when no local branch exists" {
  make_repo "$FIX/origin" main
  git -C "$FIX/origin" branch feat
  git clone -q "$FIX/origin" "$FIX/work"
  git -C "$FIX/work" config user.email t@t.t
  git -C "$FIX/work" config user.name  t
  local wt="$FIX/wt"
  # Detached worktree, and 'feat' exists only as origin/feat (no local branch).
  git -C "$FIX/work" worktree add --detach -q "$wt"

  run ensure_worktree "$FIX/work" "$wt" feat
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "feat" ]
}

@test "ensure_worktree: refuses (non-zero) when detached HEAD cannot be recovered" {
  make_repo "$FIX/repo" main
  local wt="$FIX/wt"
  git -C "$FIX/repo" worktree add --detach -q "$wt"

  run ensure_worktree "$FIX/repo" "$wt" ghost   # no local 'ghost', no origin
  [ "$status" -ne 0 ]
  [[ "$output" == *detached* ]]
}

@test "ensure_worktree: clears an orphaned (non-worktree) directory and recreates it" {
  make_repo "$FIX/repo" main
  git -C "$FIX/repo" branch feat
  local wt="$FIX/wt"
  mkdir -p "$wt"; echo junk > "$wt/leftover"   # a plain dir squatting on the path

  run ensure_worktree "$FIX/repo" "$wt" feat
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "feat" ]
  [ ! -f "$wt/leftover" ]
}

@test "ensure_worktree: relocates a branch checked out in a stale worktree (WS_ASSUME_YES)" {
  make_repo "$FIX/repo" main
  git -C "$FIX/repo" branch feat
  local stale="$FIX/stale" wt="$FIX/wt"
  git -C "$FIX/repo" worktree add -q "$stale" feat   # feat already checked out elsewhere

  WS_ASSUME_YES=1 run ensure_worktree "$FIX/repo" "$wt" feat
  [ "$status" -eq 0 ]
  [ "$(head_branch "$wt")" = "feat" ]
  [ ! -d "$stale" ]   # the stale worktree was removed
}
