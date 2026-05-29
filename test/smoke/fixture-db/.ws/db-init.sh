#!/bin/sh
set -e

# Wait for the postgres service to accept connections, then drop the marker the
# healthcheck looks for. Mirrors the real recipe's pg_isready wait loop.
echo "==> Waiting for PostgreSQL..."
until pg_isready -h db -U postgres; do sleep 1; done

touch /tmp/.db_initialized

# Durable run counter on the bind-mounted worktree (/app == host worktree dir).
# Survives the app-container recreation that follows first_run, and is readable
# from the host, so the smoke harness can prove `ws db-restore` ACTUALLY re-ran
# this script (counter incremented) rather than trusting the exit code alone.
count_file=/app/.db_init_count
prev=0
[ -f "$count_file" ] && prev=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((prev + 1))
echo "$count" > "$count_file"

echo "ready (db-init run #$count)"
