#!/usr/bin/env bash
# Git-worktree provisioning for a Session (stack-agnostic, no docker/tmux).
#
# Owns the two git concerns that used to be inlined (and untested) inside
# cmd_attach: resolving the Base ref a new worktree branches from, and the
# worktree state machine (create / recover detached HEAD / clear orphan / move a
# branch checked out elsewhere) behind one invariant — see ensure_worktree.
# Relies on lib/colors.sh helpers (info/warn/error/success/confirm).

# Resolve the Base ref to branch (or build) from, degrading gracefully for
# repos with no 'origin' remote. Echoes one of: origin/<main_branch>, the local
# <main_branch>, or HEAD. Best-effort `git fetch` when an origin exists.
resolve_base_ref() {
  local repo_root="$1" main_branch="$2" ref
  if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo_root" fetch origin >/dev/null 2>&1 || true
    ref="origin/$main_branch"
  else
    ref="$main_branch"
  fi
  if ! git -C "$repo_root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    ref="$main_branch"
    git -C "$repo_root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || ref="HEAD"
  fi
  echo "$ref"
}

# Guarantee a worktree exists at <worktree_path>, checked out on <branch>, or
# fail (non-zero) without leaving something we'd launch into. Owns the whole
# git state machine:
#   * orphaned dir (exists, not a worktree)        → remove + prune, then create
#   * existing valid worktree (maybe detached HEAD) → recover onto <branch>
#   * no worktree yet, base_ref given               → create a NEW branch off it
#   * no worktree yet, no base_ref                   → check out the existing
#       branch, relocating it if it's parked in a stale worktree elsewhere
#
#   ensure_worktree <repo_root> <worktree_path> <branch> [<base_ref>]
# base_ref present → new-branch mode; absent/empty → existing-branch mode.
ensure_worktree() {
  local repo_root="$1" worktree_path="$2" branch="$3" base_ref="${4:-}"

  # An orphaned directory (exists but is not a git worktree) squatting on the
  # path — clear it so the create/recover paths below see a clean slate.
  if [[ -d "$worktree_path" ]] && ! git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1; then
    warn "Orphaned directory found at $worktree_path — removing..."
    rm -rf "$worktree_path"
    git -C "$repo_root" worktree prune 2>/dev/null || true
  fi

  # Existing valid worktree: make sure it's on $branch (never launch a session in
  # detached HEAD — commits made there are silently lost).
  if [[ -d "$worktree_path" ]]; then
    local current_head
    current_head=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
    if [[ "$current_head" == "DETACHED" ]]; then
      warn "Worktree at $worktree_path is in detached HEAD — attempting to fix..."
      if git -C "$worktree_path" checkout "$branch" 2>/dev/null; then
        success "Now tracking branch: $branch"
      elif git -C "$worktree_path" checkout -b "$branch" "origin/$branch" 2>/dev/null; then
        success "Created and tracking: $branch"
      else
        warn "Automatic checkout failed."
      fi
      if ! git -C "$worktree_path" symbolic-ref --short HEAD >/dev/null 2>&1; then
        error "Worktree at $worktree_path is still in detached HEAD; refusing to launch."
        error "Fix manually: git -C \"$worktree_path\" checkout $branch"
        return 1
      fi
    fi
    return 0
  fi

  # No worktree yet — create one.
  if [[ -n "$base_ref" ]]; then
    git -C "$repo_root" worktree add -b "$branch" "$worktree_path" "$base_ref" \
      || { error "Could not create worktree for new branch '$branch'."; return 1; }
    return 0
  fi

  # Existing-branch mode: the branch may already be parked in a stale worktree
  # (e.g. an old session dir). Offer to relocate it here.
  if git -C "$repo_root" worktree add "$worktree_path" "$branch" 2>/dev/null; then
    return 0
  fi
  local stale_path
  stale_path=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null \
    | awk -v b="$branch" '/^worktree /{p=$2} /^branch refs\/heads\//{if ($2 == "refs/heads/"b) print p}')
  if [[ -n "$stale_path" && "$stale_path" != "$worktree_path" ]]; then
    warn "Branch '$branch' is checked out in a stale worktree at: $stale_path"
    if confirm "Remove stale worktree and continue?" Y; then
      git -C "$repo_root" worktree remove --force "$stale_path" 2>/dev/null || true
      git -C "$repo_root" worktree prune 2>/dev/null || true
      git -C "$repo_root" worktree add "$worktree_path" "$branch" \
        || { error "Still could not create worktree."; return 1; }
      return 0
    fi
    error "Cannot create session — branch is checked out elsewhere."
    return 1
  fi
  error "Could not create worktree for '$branch'."
  return 1
}
