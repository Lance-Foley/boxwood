#!/usr/bin/env bash
# Git worktree, .env, and session file helpers

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50
}

timestamp() {
  date +"%Y%m%d-%H%M"
}

timestamp_readable() {
  date +"%Y-%m-%d %H:%M"
}

worktree_create() {
  local branch="$1"
  local repo_root="${WESCOM_APP_PATH:-$HOME/code/WescomApp}"
  local worktree_path="$repo_root/.claude/worktrees/$branch"

  info "Creating worktree at ${BOLD}${worktree_path}${NC}" >&2

  # Ensure .claude/worktrees directory exists
  mkdir -p "$repo_root/.claude/worktrees"

  if git -C "$repo_root" worktree add -b "$branch" "$worktree_path" >/dev/null 2>&1; then
    success "Worktree created: $worktree_path" >&2
    echo "$worktree_path"
    return 0
  else
    error "Failed to create worktree for branch: $branch"
    return 1
  fi
}

worktree_attach() {
  local branch="$1"
  local repo_root="${WESCOM_APP_PATH:-$HOME/code/WescomApp}"
  local worktree_path="$repo_root/.claude/worktrees/$branch"

  info "Creating worktree at ${BOLD}${worktree_path}${NC}" >&2

  # mkdir -p on parent dir to handle slashes in branch names
  # e.g. feature/foo needs .claude/worktrees/feature/ to exist
  mkdir -p "$(dirname "$worktree_path")"

  if git -C "$repo_root" worktree add "$worktree_path" "$branch" >/dev/null 2>&1; then
    success "Worktree created: $worktree_path" >&2
    echo "$worktree_path"
    return 0
  else
    error "Failed to create worktree for branch: $branch"
    return 1
  fi
}

worktree_remove() {
  local branch="$1"
  local repo_root="${WESCOM_APP_PATH:-$HOME/code/WescomApp}"
  local worktree_path="$repo_root/.claude/worktrees/$branch"

  info "Removing worktree ${BOLD}${worktree_path}${NC}"

  if git -C "$repo_root" worktree remove --force "$worktree_path" 2>/dev/null; then
    git -C "$repo_root" worktree prune 2>/dev/null
    success "Worktree removed"
    return 0
  else
    error "Failed to remove worktree: $worktree_path"
    return 1
  fi
}

worktree_setup_env() {
  local worktree_path="$1"
  local db_name="$2"
  local repo_root="${WESCOM_APP_PATH:-$HOME/code/WescomApp}"

  # Copy .env from repo root
  if [[ -f "$repo_root/.env" ]]; then
    cp "$repo_root/.env" "$worktree_path/.env"
    # Override DATABASE_URL
    if grep -q "^DATABASE_URL=" "$worktree_path/.env"; then
      sed -i '' "s|^DATABASE_URL=.*|DATABASE_URL=postgres://localhost/$db_name|" "$worktree_path/.env"
    else
      echo "DATABASE_URL=postgres://localhost/$db_name" >> "$worktree_path/.env"
    fi
    # Disable Solid Queue in Puma (crashes on macOS fork in worktrees)
    if grep -q "^SOLID_QUEUE_IN_PUMA=" "$worktree_path/.env"; then
      sed -i '' "s|^SOLID_QUEUE_IN_PUMA=.*|SOLID_QUEUE_IN_PUMA=false|" "$worktree_path/.env"
    else
      echo "SOLID_QUEUE_IN_PUMA=false" >> "$worktree_path/.env"
    fi
    success "Environment configured with isolated database"
  else
    # Create minimal .env
    printf "DATABASE_URL=postgres://localhost/%s\nSOLID_QUEUE_IN_PUMA=false\n" "$db_name" > "$worktree_path/.env"
    warn "No .env found in repo root — created minimal .env"
  fi

  # Remove Solid Queue Puma plugin in worktrees (crashes on macOS due to fork safety)
  local puma_rb="$worktree_path/config/puma.rb"
  if [[ -f "$puma_rb" ]] && grep -q "plugin :solid_queue" "$puma_rb"; then
    sed -i '' '/plugin :solid_queue/d' "$puma_rb"
    success "Patched puma.rb: removed Solid Queue plugin"
  fi

  # Disable Puma cluster mode (macOS objc fork crash in worktrees)
  if grep -q "^WEB_CONCURRENCY=" "$worktree_path/.env"; then
    sed -i '' "s|^WEB_CONCURRENCY=.*|WEB_CONCURRENCY=0|" "$worktree_path/.env"
  else
    echo "WEB_CONCURRENCY=0" >> "$worktree_path/.env"
  fi

  # Ensure Procfile.dev uses $PORT (older branches may have hard-coded port)
  local procfile="$worktree_path/Procfile.dev"
  if [[ -f "$procfile" ]] && grep -q "server -p [0-9]" "$procfile"; then
    sed -i '' 's|server -p [0-9]*|server -p \$PORT|' "$procfile"
    success "Patched Procfile.dev: uses \$PORT"
  fi

  # Ensure bin/dev has port auto-detection
  local bindev="$worktree_path/bin/dev"
  if [[ -f "$bindev" ]] && ! grep -q "lsof" "$bindev"; then
    cp "$repo_root/bin/dev" "$bindev"
    success "Updated bin/dev: added port auto-detection"
  fi
}

write_session_notes() {
  local worktree_path="$1"
  local title="$2"
  local branch="$3"
  local db_name="$4"
  local notion_url="$5"
  local description="$6"
  local page_content="$7"
  local comments="$8"
  local now
  now=$(timestamp_readable)

  cat > "$worktree_path/SESSION_NOTES.md" <<EOF
# Session Notes — ${title}

> **Started:** ${now}
> **Branch:** \`${branch}\`
> **Database:** \`${db_name}\`
> **Notion:** ${notion_url}

---

## Task Description

${description}

---

## Notion Page Content

${page_content}

---

## Comments

${comments}

---

## Sync History

- ${now} — Session started
EOF

  success "SESSION_NOTES.md written"
}

write_claude_md() {
  local worktree_path="$1"
  local branch="$2"
  local db_name="$3"
  local notion_url="$4"
  local repo_root="${WESCOM_APP_PATH:-$HOME/code/WescomApp}"

  local existing_claude_md=""
  if [[ -f "$repo_root/CLAUDE.md" ]]; then
    existing_claude_md=$(cat "$repo_root/CLAUDE.md")
  fi

  cat > "$worktree_path/CLAUDE.md" <<EOF
# Claude Code — Session Context

## This Session
- **Branch:** \`${branch}\`
- **Database:** \`${db_name}\` (isolated clone of wescomapp_development)
- **Notion task:** ${notion_url}

## Read Session Notes First
Before writing any code, read SESSION_NOTES.md in this directory.
It has the task description, Notion context, and all synced notes.

\`\`\`
cat SESSION_NOTES.md
\`\`\`

When the user says "sync" or "re-read notes", read SESSION_NOTES.md again.

## Database
This worktree uses isolated database: \`${db_name}\`
Safe to run migrations and seeds. Does not affect wescomapp_development.
Rails uses it automatically via .env in this directory.

---

${existing_claude_md}
EOF

  success "CLAUDE.md written"
}

# Detect session from current directory
detect_session_from_cwd() {
  local cwd="$1"
  local sessions_file="$HOME/.wescom-sessions.json"

  if [[ ! -f "$sessions_file" ]]; then
    return 1
  fi

  jq -r --arg cwd "$cwd" '
    .[] | select(.status == "active" and .worktree_path == $cwd) | .branch
  ' "$sessions_file"
}

# Get session info by branch
get_session_by_branch() {
  local branch="$1"
  local sessions_file="$HOME/.wescom-sessions.json"

  if [[ ! -f "$sessions_file" ]]; then
    return 1
  fi

  jq --arg branch "$branch" '.[] | select(.branch == $branch)' "$sessions_file"
}
