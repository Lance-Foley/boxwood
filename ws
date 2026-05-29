#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks to find the real script dir
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# Library files
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# ─── boxwood home ─────────────────────────────────────────────────────────────
: "${WS_HOME:=$HOME/.ws}"
SESSIONS_DIR="$WS_HOME/sessions"
REGISTRY="$WS_HOME/registry.json"

mkdir -p "$SESSIONS_DIR"
[[ -f "$REGISTRY" ]] || echo '[]' > "$REGISTRY"

# Per-command repo context (set by load_repo_context / require_config)
REPO_ROOT=""; REPO=""; CONFIG=""; CONFIG_JSON=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's|/|-|g; s/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50
}

registry_add() {
  local repo="$1" branch="$2" project="$3" port="$4" path="$5" pr="${6:-null}"
  local now tmp
  now=$(date +"%Y-%m-%d %H:%M"); tmp=$(mktemp)
  jq --arg r "$repo" --arg b "$branch" --arg pj "$project" --argjson p "$port" \
     --arg pt "$path" --argjson pr "$pr" --arg s "$now" \
     '. + [{repo:$r, branch:$b, project:$pj, port:$p, path:$pt, pr:$pr, started:$s, status:"active"}]' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

registry_end() {
  local repo="$1" branch="$2" tmp
  tmp=$(mktemp)
  jq --arg r "$repo" --arg b "$branch" \
     'map(if .repo == $r and .branch == $b then .status = "ended" else . end)' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

registry_prune() {
  local cutoff tmp
  cutoff=$(date -v-30d +"%Y-%m-%d" 2>/dev/null || date -d "30 days ago" +"%Y-%m-%d" 2>/dev/null) || true
  # On a host where neither date form works, cutoff is empty. Running jq with an
  # empty cutoff makes `.started > ""` true for every entry by accident — undefined
  # behavior. Fail safe: keep all entries (no data loss) and let a later attach on
  # a healthy host prune normally.
  if [[ -z "$cutoff" ]]; then
    warn "registry_prune: could not compute a 30-day cutoff (no compatible 'date') — skipping prune."
    return 0
  fi
  tmp=$(mktemp)
  jq --arg c "$cutoff" \
     '[.[] | select(.status == "active" or .started > $c)]' \
     "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

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

find_session_by_cwd() {
  local cwd="$1"
  jq -r --arg cwd "$cwd" '
    .[] | select(.status == "active" and ((.path // "") as $p | $p != "" and ($cwd | startswith($p)))) | .branch
  ' "$REGISTRY" | head -1
}

# Resolve the Assistant command from the per-user config.
#   key absent          → "claude" (default)
#   key present, blank  → ""        (plain shell)
#   key present, value  → that value
# Caller must have run load_user_config first.
resolve_assistant_command() {
  local has_key
  has_key=$(echo "$USER_CONFIG_JSON" | jq -r 'try (.assistant | has("command")) catch false' 2>/dev/null)
  if [[ "$has_key" == "true" ]]; then
    ucfg '.assistant.command'
  else
    echo "claude"
  fi
}

setup_worktree() {
  local worktree_path="$1" branch="$2" port="$3" pr="${4:-}"

  # Copy secrets from the main checkout into the worktree's .env (compose env_file).
  local secrets; secrets=$(cfg_default '.secrets_file' '.env')
  if [[ -f "$REPO_ROOT/$secrets" ]]; then
    cp "$REPO_ROOT/$secrets" "$worktree_path/.env"
  else
    touch "$worktree_path/.env"
  fi

  mkdir -p "$worktree_path/.session/memory"

  # Where the session-context block lands depends on the Assistant: Claude reads
  # CLAUDE.md, anything else (or no assistant) gets a neutral .session/CONTEXT.md.
  load_user_config
  local assistant context_file
  assistant=$(resolve_assistant_command)
  if [[ "$assistant" == *claude* ]]; then
    context_file="CLAUDE.md"
  else
    context_file=".session/CONTEXT.md"
  fi

  cat >> "$worktree_path/$context_file" <<EOF

# Session Context
- Repo: $REPO
- Branch: $branch
- Port: $port (http://localhost:$port)
${pr:+- PR: #$pr}

This is an isolated boxwood worktree session running in Docker containers.
Run commands inside the container via: ws exec <command>
e.g. ws exec rails console

Use .session/memory/ to track decisions, progress, and context about this work.
EOF

  # Git excludes so session files don't show as dirty
  local git_dir
  git_dir=$(git -C "$worktree_path" rev-parse --git-dir)
  mkdir -p "$git_dir/info"
  for f in "$context_file" .session/ .env docker-compose.yml; do
    grep -qxF "$f" "$git_dir/info/exclude" 2>/dev/null || echo "$f" >> "$git_dir/info/exclude"
  done
}

launch_tmux() {
  if [[ -n "${WS_NO_ATTACH:-}" ]]; then return 0; fi

  local full_session="$1" worktree_path="$2" project="$3" port="$4" pr_number="$5"

  local app_service editor assistant_cmd skipperm
  app_service=$(cfg_default '.compose.app_service' 'app')

  # In-tmux editor: per-user config → $EDITOR → nvim.
  load_user_config
  editor=$(ucfg '.editor')
  [[ -z "$editor" ]] && editor="${EDITOR:-}"
  [[ -z "$editor" ]] && editor="nvim"

  # Assistant pane: per-user config (key absent → claude; blank → plain shell).
  assistant_cmd=$(resolve_assistant_command)
  skipperm=$(ucfg '.assistant.skip_permissions')
  if [[ -z "$assistant_cmd" ]]; then
    assistant_cmd="bash"
  elif [[ "$assistant_cmd" == *claude* && "$skipperm" == "true" ]]; then
    assistant_cmd="$assistant_cmd --dangerously-skip-permissions"
  fi

  # Ghostty tab title
  local tab_title="localhost:${port}"
  if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
    tab_title="PR #${pr_number} — localhost:${port}"
  fi
  printf '\033]0;%s\007' "$tab_title"

  # External GUI editor: only if the per-user config names one.
  local gui; gui=$(ucfg '.gui_editor')
  [[ -n "$gui" ]] && open -a "$gui" "$worktree_path" 2>/dev/null &

  if tmux has-session -t "$full_session" 2>/dev/null; then
    info "Reattaching to tmux session: $full_session"
    if [[ -n "${TMUX:-}" ]]; then
      exec tmux switch-client -t "$full_session"
    else
      exec tmux attach -t "$full_session"
    fi
  fi

  # ┌──────────────┬──────────────┐
  # │  Neovim      │  Claude Code │
  # │  (2/3 height)│  (2/3 height)│
  # ├──────────────┼──────────────┤
  # │  App logs    │  Container   │
  # │  (1/3 height)│  Shell       │
  # └──────────────┴──────────────┘
  # The dev server runs as the app container's own command (docs/adr/0001), so
  # the bottom-left pane tails its logs rather than launching it.
  info "Starting tmux session: $full_session"
  tmux new-session -d -s "$full_session" -c "$worktree_path"
  tmux source-file "$SCRIPT_DIR/tmux.conf" 2>/dev/null || true

  local pane_nvim pane_dev pane_claude pane_shell
  pane_nvim=$(tmux display-message -t "$full_session" -p '#{pane_id}')
  pane_dev=$(tmux split-window -v -t "$pane_nvim" -c "$worktree_path" -l 33% -P -F '#{pane_id}')
  pane_claude=$(tmux split-window -h -t "$pane_nvim" -c "$worktree_path" -P -F '#{pane_id}')
  pane_shell=$(tmux split-window -h -t "$pane_dev" -c "$worktree_path" -P -F '#{pane_id}')

  local compose="docker compose -p $project -f $worktree_path/docker-compose.yml"
  tmux send-keys -t "$pane_nvim" "$editor ." Enter
  tmux send-keys -t "$pane_claude" "$assistant_cmd" Enter
  tmux send-keys -t "$pane_dev" "$compose logs -f $app_service" Enter
  tmux send-keys -t "$pane_shell" "$compose exec $app_service bash" Enter
  tmux select-pane -t "$pane_nvim"

  if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "$full_session"
  else
    exec tmux attach -t "$full_session"
  fi
}

# ─── ws init ──────────────────────────────────────────────────────────────────

cmd_init() {
  local template="rails-postgres"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template) template="$2"; shift 2 ;;
      *) error "Unknown argument: $1"; exit 1 ;;
    esac
  done

  load_repo_context

  local src="$SCRIPT_DIR/templates/$template/.ws"
  if [[ ! -d "$src" ]]; then
    error "No such template: $template"
    info  "Available: $(ls "$SCRIPT_DIR/templates" 2>/dev/null | tr '\n' ' ')"
    exit 1
  fi

  local dest="$REPO_ROOT/.ws"
  if [[ -d "$dest" ]]; then
    error ".ws/ already exists in $REPO_ROOT — nothing to do."
    exit 1
  fi

  cp -R "$src" "$dest"

  # Warn (loudly) if this repo's .gitignore would prevent .ws/ from being
  # committed — otherwise teammates clone a repo with no recipe and `ws attach`
  # errors with "No .ws/config.yml found". WARN ONLY: never mutate .gitignore.
  if git -C "$REPO_ROOT" check-ignore -q .ws 2>/dev/null; then
    warn ".ws/ is gitignored in this repo — teammates won't get the recipe."
    echo -e "  Fix: append ${BOLD}!.ws/${NC} to $REPO_ROOT/.gitignore so the recipe is committable."
  fi

  header "Scaffolded .ws/ ($template) in $REPO"
  echo -e "  Edit ${BOLD}.ws/config.yml${NC} and the Docker assets to match this repo, then:"
  echo -e "    ${BOLD}ws rebuild${NC}                      # build the base image"
  echo -e "    ${BOLD}ws attach --new \"My session\"${NC}    # start your first session"
  echo ""
  dim "  Tip: commit .ws/ so teammates get the same session recipe."
}

# ─── ws attach ────────────────────────────────────────────────────────────────

cmd_attach() {
  local branch="" pr_number="" new_name="" reset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)     pr_number="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --new)    new_name="$2"; shift 2 ;;
      --reset)  reset=1; shift ;;
      *)        error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  local modes=0
  [[ -n "$pr_number" ]] && modes=$((modes + 1))
  [[ -n "$branch" ]] && modes=$((modes + 1))
  [[ -n "$new_name" ]] && modes=$((modes + 1))
  if [[ "$modes" -ne 1 ]]; then
    error "Provide exactly one of --pr, --branch, or --new."
    usage; exit 1
  fi

  require_config

  local image_name main_branch
  image_name=$(cfg '.image.name')
  main_branch=$(cfg_default '.main_branch' 'main')

  if [[ -z "$image_name" ]]; then
    error "image.name missing in .ws/config.yml"; exit 1
  fi
  if ! image_exists "$image_name"; then
    error "Base image '$image_name' not found. Run 'ws rebuild' first."
    exit 1
  fi

  registry_prune

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

  if [[ -n "$new_name" ]]; then
    branch=$(slugify "$new_name")
    info "Creating new branch: $branch"
  fi

  local repo_slug dir_name worktree_path project tmux_session
  repo_slug=$(slugify "$REPO")
  dir_name=$(slugify "$branch")
  mkdir -p "$SESSIONS_DIR/$REPO"
  worktree_path="$SESSIONS_DIR/$REPO/$dir_name"
  project=$(compose_project_name "$repo_slug" "$dir_name")
  tmux_session="$project"

  # Slug collision within this repo
  local existing_branch
  existing_branch=$(jq -r --arg r "$REPO" --arg d "$dir_name" --arg b "$branch" \
    '.[] | select(.status == "active" and .repo == $r and .branch != $b and ((.path // "") | endswith("/"+$d))) | .branch' \
    "$REGISTRY" | head -1)
  if [[ -n "$existing_branch" ]]; then
    error "Directory name '$dir_name' is already used by branch '$existing_branch' in $REPO."
    exit 1
  fi

  # Clean up an orphaned (non-worktree) directory
  if [[ -d "$worktree_path" ]] && ! git -C "$worktree_path" rev-parse --git-dir > /dev/null 2>&1; then
    warn "Orphaned directory found at $worktree_path — removing..."
    rm -rf "$worktree_path"
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  fi

  # ── Resume / restart an existing worktree ──
  if [[ -d "$worktree_path" ]]; then
    info "Existing worktree found at $worktree_path"

    local current_head
    current_head=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
    if [[ "$current_head" == "DETACHED" ]]; then
      warn "Worktree is in detached HEAD state — attempting to fix..."
      if git -C "$worktree_path" checkout "$branch" 2>/dev/null; then
        success "Now tracking branch: $branch"
      elif git -C "$worktree_path" checkout -b "$branch" "origin/$branch" 2>/dev/null; then
        success "Created and tracking: $branch"
      else
        warn "Automatic checkout failed."
      fi
      # Re-verify: never launch a session in detached HEAD (commits there are lost).
      if ! git -C "$worktree_path" symbolic-ref --short HEAD >/dev/null 2>&1; then
        error "Worktree at $worktree_path is still in detached HEAD; refusing to launch."
        error "Fix manually: git -C \"$worktree_path\" checkout $branch"
        exit 1
      fi
    fi

    local port
    port=$(jq -r --arg r "$REPO" --arg b "$branch" '.[] | select(.repo == $r and .branch == $b and .status == "active") | .port' "$REGISTRY" | head -1)
    if [[ -z "$port" || "$port" == "null" ]]; then port=$(next_port) || exit 1; fi
    if [[ -z "$pr_number" ]]; then
      pr_number=$(jq -r --arg r "$REPO" --arg b "$branch" '.[] | select(.repo == $r and .branch == $b and .status == "active") | .pr // empty' "$REGISTRY" | head -1)
    fi

    [[ -f "$worktree_path/.env" ]] || setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"

    local state
    state=$(detect_session_state "$project")
    if [[ "$state" == "resume" ]]; then
      info "Containers already running"
    else
      if [[ "$state" != "first_run" ]] && project_has_volumes "$project" && has_db; then
        # --reset drops outright (explicit consent, no inner prompt). Without it,
        # this is a DESTRUCTIVE confirm (default N): under WS_ASSUME_YES it
        # auto-NOs, so a scripted attach PRESERVES the existing database.
        if [[ -n "$reset" ]] || confirm "Database exists from a previous run. Drop and re-initialize?" N; then
          compose_down "$project" "$worktree_path"; state="first_run"
        fi
      fi
      compose_up "$project" "$worktree_path" "$port" "$state"
    fi

    local in_registry
    in_registry=$(jq -r --arg r "$REPO" --arg b "$branch" '.[] | select(.repo == $r and .branch == $b and .status == "active") | .branch' "$REGISTRY" | head -1)
    [[ -z "$in_registry" ]] && registry_add "$REPO" "$branch" "$project" "$port" "$worktree_path" "${pr_number:-null}"

    launch_tmux "${tmux_session}_${port}" "$worktree_path" "$project" "$port" "${pr_number:-}"
    exit 0
  fi

  # ── New session — create worktree ──
  info "Creating session for branch: $branch"

  # Resolve the base ref for new worktrees, degrading gracefully when there is
  # no 'origin' remote (local-only / GitLab / non-origin repos).
  local base_ref
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO_ROOT" fetch origin >/dev/null 2>&1 || true
    base_ref="origin/$main_branch"
  else
    base_ref="$main_branch"
  fi
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    base_ref="$main_branch"
    git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || base_ref="HEAD"
  fi

  if [[ -n "$new_name" ]]; then
    git -C "$REPO_ROOT" worktree add -b "$branch" "$worktree_path" "$base_ref"
  else
    git -C "$REPO_ROOT" worktree add "$worktree_path" "$branch" 2>/dev/null || {
      local stale_path
      stale_path=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
        | awk -v b="$branch" '/^worktree /{p=$2} /^branch refs\/heads\//{if ($2 == "refs/heads/"b) print p}')
      if [[ -n "$stale_path" && "$stale_path" != "$worktree_path" ]]; then
        warn "Branch '$branch' is checked out in a stale worktree at: $stale_path"
        if confirm "Remove stale worktree and continue?" Y; then
          git -C "$REPO_ROOT" worktree remove --force "$stale_path" 2>/dev/null || true
          git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
          git -C "$REPO_ROOT" worktree add "$worktree_path" "$branch" || { error "Still could not create worktree."; exit 1; }
        else
          error "Cannot create session — branch is checked out elsewhere."; exit 1
        fi
      else
        error "Could not create worktree for '$branch'."; exit 1
      fi
    }
  fi
  success "Worktree created at $worktree_path"

  local port; port=$(next_port) || exit 1

  setup_worktree "$worktree_path" "$branch" "$port" "${pr_number:-}"
  compose_up "$project" "$worktree_path" "$port" "first_run"
  registry_add "$REPO" "$branch" "$project" "$port" "$worktree_path" "${pr_number:-null}"

  header "Session Ready"
  echo -e "  ${BOLD}Repo:${NC}      $REPO"
  echo -e "  ${BOLD}Branch:${NC}    $branch"
  echo -e "  ${BOLD}Port:${NC}      $port → http://localhost:$port"
  echo -e "  ${BOLD}Path:${NC}      $worktree_path"
  echo ""

  launch_tmux "${tmux_session}_${port}" "$worktree_path" "$project" "$port" "${pr_number:-}"
}

# ─── ws list ──────────────────────────────────────────────────────────────────

cmd_list() {
  local all=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|-a) all=true; shift ;;
      *) error "Unknown option: $1"; exit 1 ;;
    esac
  done

  local filter='.[] | select(.status == "active")'
  local scope="All repos"
  if [[ "$all" == false ]]; then
    load_repo_context
    filter=".[] | select(.status == \"active\" and .repo == \"$REPO\")"
    scope="$REPO"
  fi

  header "Active Sessions — $scope"

  local active count
  active=$(jq "[$filter]" "$REGISTRY")
  count=$(echo "$active" | jq 'length')
  if [[ "$count" == "0" ]]; then dim "  No active sessions."; return; fi

  if [[ "$all" == true ]]; then
    printf "  ${BOLD}%-16s %-22s %-5s %-22s %-12s %s${NC}\n" "REPO" "BRANCH" "PR" "URL" "CONTAINERS" "STARTED"
    echo "  $(printf '%.0s─' {1..90})"
    echo "$active" | jq -r '.[] | "\(.repo)\t\(.branch)\t\(.port // "?")\t\(.pr // "")\t\(.started)\t\(.project)"' |
    while IFS=$'\t' read -r repo branch port pr started project; do
      local status pr_disp
      status=$(compose_status_display "$project")
      pr_disp="${pr:+#$pr}"
      printf "  %-16s %-22s %-5s %-22s %-12b %s\n" "${repo:0:14}" "${branch:0:20}" "$pr_disp" "http://localhost:$port" "$status" "$started"
    done
  else
    printf "  ${BOLD}%-26s %-5s %-22s %-12s %s${NC}\n" "BRANCH" "PR" "URL" "CONTAINERS" "STARTED"
    echo "  $(printf '%.0s─' {1..82})"
    echo "$active" | jq -r '.[] | "\(.branch)\t\(.port // "?")\t\(.pr // "")\t\(.started)\t\(.project)"' |
    while IFS=$'\t' read -r branch port pr started project; do
      local status pr_disp
      status=$(compose_status_display "$project")
      pr_disp="${pr:+#$pr}"
      printf "  %-26s %-5s %-22s %-12b %s\n" "${branch:0:24}" "$pr_disp" "http://localhost:$port" "$status" "$started"
    done
  fi
}

# ─── ws end ───────────────────────────────────────────────────────────────────

cmd_end() {
  local branch="" push=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)   branch="$2"; shift 2 ;;
      --push)     push="yes"; shift ;;
      --no-push)  push="no"; shift ;;
      -*)         error "Unknown option: $1"; exit 1 ;;
      *)          branch="$1"; shift ;;
    esac
  done

  load_repo_context

  if [[ -z "$branch" ]]; then
    branch=$(find_session_by_cwd "$(pwd)")
    if [[ -z "$branch" ]]; then
      error "Not in a session directory. Use --branch <name>."; exit 1
    fi
  fi

  local session
  session=$(jq --arg r "$REPO" --arg b "$branch" '.[] | select(.repo == $r and .branch == $b and .status == "active")' "$REGISTRY")
  if [[ -z "$session" ]]; then error "No active session for branch: $branch"; exit 1; fi

  local worktree_path port project
  worktree_path=$(echo "$session" | jq -r '.path')
  port=$(echo "$session" | jq -r '.port')
  project=$(echo "$session" | jq -r '.project')

  local main_branch; main_branch=$(cfg_default '.main_branch' 'main')

  header "Ending session: $REPO / $branch"

  if [[ -d "$worktree_path" ]]; then
    local ahead dirty
    ahead=$(git -C "$worktree_path" rev-list --count "${main_branch}..HEAD" 2>/dev/null || echo "0")
    dirty=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    info "Commits ahead of $main_branch: $ahead"
    info "Uncommitted files: $dirty"
    echo ""
  fi

  # Push is DESTRUCTIVE-by-default (publishes work): with neither flag the confirm
  # defaults to N, so WS_ASSUME_YES auto-NOs (no accidental push). --push forces
  # it; --no-push skips it.
  if [[ "$push" == "yes" ]] || { [[ -z "$push" ]] && confirm "Push branch to origin?" N; }; then
    git -C "$worktree_path" push -u origin "$branch" 2>/dev/null && success "Branch pushed" || warn "Push failed"
    echo ""
  fi

  info "Stopping containers and removing volumes..."
  compose_down "$project" "$worktree_path"
  success "Containers stopped, volumes removed"
  echo ""

  if confirm "Remove worktree and local branch?" Y; then
    [[ "$(pwd)" == "$worktree_path"* ]] && cd "$HOME"
    git -C "$REPO_ROOT" worktree remove --force "$worktree_path" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    success "Worktree removed"
    git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null && success "Local branch '$branch' deleted" || true
    [[ -d "$worktree_path" ]] && rm -rf "$worktree_path"
    echo ""
  fi

  registry_end "$REPO" "$branch"
  success "Session ended: $branch"

  tmux kill-session -t "${project}_${port}" 2>/dev/null \
    || tmux kill-session -t "$project" 2>/dev/null || true
  success "Tmux session killed"
}

# ─── ws rebuild ───────────────────────────────────────────────────────────────

cmd_rebuild() {
  require_config
  header "Rebuilding base image for $REPO"

  local image_name dockerfile main_branch
  image_name=$(cfg '.image.name')
  dockerfile=$(cfg_default '.image.dockerfile' '.ws/Dockerfile')
  main_branch=$(cfg_default '.main_branch' 'main')
  [[ -z "$image_name" ]] && { error "image.name missing in .ws/config.yml"; exit 1; }
  [[ -f "$REPO_ROOT/$dockerfile" ]] || { error "Dockerfile not found: $REPO_ROOT/$dockerfile"; exit 1; }

  info "Fetching latest $main_branch..."
  local src_ref
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO_ROOT" fetch origin >/dev/null 2>&1 || true
    src_ref="origin/$main_branch"
  else
    src_ref="$main_branch"
  fi
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$src_ref" >/dev/null 2>&1 || src_ref="$main_branch"
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$src_ref" >/dev/null 2>&1 || src_ref="HEAD"

  # build_ctx is intentionally NOT local: the EXIT trap fires in global scope,
  # where a function-local would be unset (fatal under set -u, and would leak
  # the temp dir). The guard keeps the trap safe even if mktemp never ran.
  build_ctx=$(mktemp -d)
  trap 'rm -rf "${build_ctx:-}" 2>/dev/null' EXIT

  # Copy dependency files from <src_ref> into the build context root.
  info "Copying dependency files from $src_ref..."
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    mkdir -p "$build_ctx/$(dirname "$f")"
    git -C "$REPO_ROOT" show "$src_ref:$f" > "$build_ctx/$f" 2>/dev/null || {
      error "Could not read '$f' from $src_ref"; exit 1
    }
  done < <(echo "$CONFIG_JSON" | jq -r '.image.build_context_from_main[]?')

  # Dockerfile + any scripts it COPYs (entrypoint, db-init) from .ws/ into ctx root.
  cp "$REPO_ROOT/$dockerfile" "$build_ctx/Dockerfile"
  cp "$REPO_ROOT/.ws/docker-entrypoint.sh" "$build_ctx/" 2>/dev/null || true
  cp "$REPO_ROOT/.ws/db-init.sh" "$build_ctx/" 2>/dev/null || true

  info "Building image (this may take a few minutes on first run)..."
  docker build -t "$image_name" "$build_ctx"

  local size
  size=$(docker image inspect "$image_name" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')
  success "Image built: $image_name ($size)"
}

# ─── ws exec ──────────────────────────────────────────────────────────────────

cmd_exec() {
  [[ $# -eq 0 ]] && { error "Usage: ws exec <command>"; exit 1; }

  require_config
  local branch; branch=$(find_session_by_cwd "$(pwd)")
  [[ -z "$branch" ]] && { error "Not in a session directory. cd to a worktree first."; exit 1; }

  local repo_slug dir_name project worktree_path app_service
  repo_slug=$(slugify "$REPO"); dir_name=$(slugify "$branch")
  project=$(compose_project_name "$repo_slug" "$dir_name")
  worktree_path="$SESSIONS_DIR/$REPO/$dir_name"
  app_service=$(cfg_default '.compose.app_service' 'app')

  if [[ "$(compose_status "$project")" != "running" ]]; then
    error "Containers not running for '$branch'. Run 'ws attach --branch $branch' first."; exit 1
  fi

  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec "$app_service" "$@"
}

# ─── ws db-restore ────────────────────────────────────────────────────────────

cmd_db_restore() {
  local branch="" yes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      --yes)    yes=1; shift ;;
      -*)       error "Unknown option: $1"; exit 1 ;;
      *)        branch="$1"; shift ;;
    esac
  done

  require_config
  has_db || { error "This repo's .ws/config.yml has no 'db' block — nothing to restore."; exit 1; }

  if [[ -z "$branch" ]]; then
    branch=$(find_session_by_cwd "$(pwd)")
    [[ -z "$branch" ]] && { error "Not in a session directory. Use --branch <name>."; exit 1; }
  fi

  local repo_slug dir_name project worktree_path app_service db_service restore_cmd
  repo_slug=$(slugify "$REPO"); dir_name=$(slugify "$branch")
  project=$(compose_project_name "$repo_slug" "$dir_name")
  worktree_path="$SESSIONS_DIR/$REPO/$dir_name"
  app_service=$(cfg_default '.compose.app_service' 'app')
  db_service=$(cfg_default '.compose.db_service' 'db')
  restore_cmd=$(cfg '.db.restore_command')

  # An empty restore_command would make `sh -c ""` a silent no-op that still
  # reports success — refuse rather than pretend the database was reset.
  if [[ -z "$restore_cmd" ]]; then
    error "db.restore_command is empty in .ws/config.yml — nothing to run."; exit 1
  fi

  if [[ "$(compose_status "$project")" != "running" ]]; then
    error "Containers not running for '$branch'. Run 'ws attach --branch $branch' first."; exit 1
  fi

  # The restore command typically waits on the db (e.g. pg_isready) with NO
  # timeout, so a down/unhealthy db turns the restore into a silent hang. Assert
  # the db service is up and healthy first, with an actionable error.
  if ! service_healthy "$project" "$db_service"; then
    error "Database service '$db_service' is not running and healthy for '$branch'."
    error "Bring the session up first: ws attach --branch $branch"
    exit 1
  fi

  warn "This will reset the session database via: $restore_cmd"
  # --yes forces the restore (the only scriptable path). Without it this is a
  # DESTRUCTIVE confirm (default N): under WS_ASSUME_YES it auto-NOs and the
  # restore is a no-op (the `|| exit 0` returns success without resetting).
  if [[ -z "$yes" ]]; then
    confirm "Continue?" N || exit 0
  fi

  info "Restoring database..."
  # restore_command is a shell command line (not an argv): run it through one
  # shell inside the container so quoting / pipelines / env-prefixes survive.
  # sh is guaranteed present; a login shell (bash -lc) would be the wrong model.
  # set -e propagates a non-zero exit straight out of ws.
  docker compose -p "$project" -f "$worktree_path/docker-compose.yml" exec "$app_service" sh -c "$restore_cmd"
  success "Database restore complete"
}

# ─── ws update ────────────────────────────────────────────────────────────────

cmd_update() {
  header "Updating boxwood"

  # SCRIPT_DIR is the real install dir (symlinks already resolved at the top).
  if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    error "$SCRIPT_DIR is not a git checkout — cannot self-update."
    error "Reinstall or update boxwood manually."
    exit 1
  fi

  local branch
  branch=$(git -C "$SCRIPT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")

  # Refuse to pull onto a dirty tree: --ff-only would still complain, but a clear
  # up-front message beats a cryptic git error, and protects local edits.
  if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]]; then
    error "working tree dirty — commit/stash in $SCRIPT_DIR first (branch: $branch)."
    exit 1
  fi

  info "Pulling latest on '$branch' in $SCRIPT_DIR..."
  if git -C "$SCRIPT_DIR" pull --ff-only; then
    success "boxwood updated (branch: $branch)."
  else
    error "Update failed on '$branch' (not a fast-forward, or diverged from upstream)."
    error "Resolve manually: git -C $SCRIPT_DIR pull"
    exit 1
  fi
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}ws${NC} — boxwood: isolated containerized dev sessions, one per git worktree

${BOLD}Usage:${NC}
  ws init [--template <name>]              Scaffold .ws/ in the current repo
  ws attach --pr <number> [--reset]        Attach to an existing PR
  ws attach --branch <name> [--reset]      Attach to an existing branch
  ws attach --new "description" [--reset]  Create a new branch + session
  ws list [--all]                          Active sessions (current repo, or --all)
  ws end [--branch <name>] [--push|--no-push]   Tear down a session
  ws rebuild                               Build/refresh this repo's base image
  ws exec <command>                        Run a command in the session container
  ws db-restore [--branch <name>] [--yes]  Re-run the repo's DB setup
  ws update                                Update boxwood itself (git pull --ff-only)

${BOLD}Flags:${NC}
  --reset      (attach) Drop an existing session DB volume and re-initialize.
  --push       (end) Push the branch to origin without prompting.
  --no-push    (end) Skip the push (default under WS_ASSUME_YES).
  --yes        (db-restore) Reset the DB without prompting (required to script it).

${BOLD}How it works:${NC}
  Run inside any repo that has a committed .ws/ recipe (see 'ws init').
  Sessions live in ~/.ws/sessions/<repo>/<branch>/; state in ~/.ws/registry.json.

${BOLD}Prerequisites:${NC}
  Docker (OrbStack recommended), git, jq, yq, tmux; claude (optional Assistant); gh for --pr.
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

# Guarded so the script can be sourced for unit testing without dispatching.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init)       shift; cmd_init "$@" ;;
    attach)     shift; cmd_attach "$@" ;;
    list)       shift; cmd_list "$@" ;;
    end)        shift; cmd_end "$@" ;;
    rebuild)    cmd_rebuild ;;
    exec)       shift; cmd_exec "$@" ;;
    db-restore) shift; cmd_db_restore "$@" ;;
    update)     cmd_update ;;
    -h|--help|help) usage ;;
    *)          usage ;;
  esac
fi
