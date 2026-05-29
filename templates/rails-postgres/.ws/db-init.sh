#!/bin/bash
# db-init.sh — set up the session database.
#
# Single source of truth for DB setup. Called by:
#   - docker-entrypoint.sh on first run (DB_INIT=true)
#   - `ws db-restore` on demand against a running container
#
# Runs inside the app container (has pg client tools + the app bundle).
#
# This starter uses `rails db:prepare` (create + load schema + seed). If your app
# bootstraps from a production dump instead, replace the body with a pg_restore
# flow — see the README's "DB from a production dump" note.
set -e

echo "==> Waiting for PostgreSQL..."
until pg_isready -h db -U postgres -q; do sleep 1; done

echo "==> Preparing database (create + schema + seed)..."
bundle exec rails db:prepare

# Marker so the app healthcheck can detect successful init.
touch /tmp/.db_initialized

echo "==> Database ready."
