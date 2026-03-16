#!/usr/bin/env bash
# PostgreSQL clone/drop helpers

db_clone() {
  local source_db="${PG_BASE_DB:-wescom_app_development}"
  local target_db="$1"
  local pg_user="${PG_USER:-$(whoami)}"

  info "Cloning database ${BOLD}${source_db}${NC} → ${BOLD}${target_db}${NC}"

  # Terminate connections and clone — retry up to 3 times if connections reconnect
  local attempt
  for attempt in 1 2 3; do
    psql -U "$pg_user" -d postgres -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$source_db' AND pid <> pg_backend_pid();" \
      > /dev/null 2>&1
    if createdb -U "$pg_user" -T "$source_db" "$target_db" 2>/dev/null; then
      success "Database created: $target_db"
      return 0
    fi
    [[ "$attempt" -lt 3 ]] && warn "Retrying clone (attempt $((attempt + 1))/3)..." && sleep 1
  done
  error "Failed to create database: $target_db"
  error "Make sure PostgreSQL is running and '$source_db' exists, and no active connections are blocking the clone."
  return 1
}

db_drop() {
  local db_name="$1"
  local pg_user="${PG_USER:-$(whoami)}"

  info "Dropping database ${BOLD}${db_name}${NC}"

  # Terminate active connections first
  psql -U "$pg_user" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name' AND pid <> pg_backend_pid();" \
    > /dev/null 2>&1

  if dropdb -U "$pg_user" "$db_name" 2>/dev/null; then
    success "Database dropped: $db_name"
    return 0
  else
    error "Failed to drop database: $db_name"
    return 1
  fi
}

db_exists() {
  local db_name="$1"
  local pg_user="${PG_USER:-$(whoami)}"
  psql -U "$pg_user" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$db_name';" 2>/dev/null | grep -q 1
}

db_list_session_dbs() {
  local pg_user="${PG_USER:-$(whoami)}"
  psql -U "$pg_user" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datname LIKE 'wescomapp_dev_%' ORDER BY datname;" 2>/dev/null
}
