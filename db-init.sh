#!/bin/bash
# db-init.sh — initialize the session database from latest.dump.
#
# Single source of truth for DB setup. Called by:
#   - docker-entrypoint.sh on first run (DB_INIT=true)
#   - `ws db-restore` on demand against a running container
#
# Runs inside the app container (has pg client tools + the app bundle).
set -e

echo "==> Waiting for PostgreSQL..."
until pg_isready -h db -U postgres -q; do sleep 1; done

echo "==> Dropping and recreating database..."
psql -h db -U postgres -c "DROP DATABASE IF EXISTS wescomapp;"
psql -h db -U postgres -c "CREATE DATABASE wescomapp;"

echo "==> Restoring latest.dump..."
# pg_restore returns non-zero on warnings (e.g. extension already exists) — tolerate those
pg_restore -h db -U postgres -d wescomapp --no-owner --no-privileges /dumps/latest.dump 2>&1 | tail -5 || true

# Verify the restore actually populated the database
TABLE_COUNT=$(psql -h db -U postgres -d wescomapp -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
if [ "$TABLE_COUNT" -lt 5 ]; then
  echo "==> ERROR: pg_restore failed — only $TABLE_COUNT tables found."
  exit 1
fi
echo "==> Restore loaded $TABLE_COUNT tables."

echo "==> Running migrations..."
bundle exec rails db:migrate

echo "==> Resetting dev passwords..."
bundle exec rake update_encrypted_passwords

# Marker so the app healthcheck can detect successful init
touch /tmp/.db_initialized

# Sanity check (also keeps the "Database ready." string the ws poller greps for)
USER_COUNT=$(psql -h db -U postgres -d wescomapp -tAc "SELECT count(*) FROM users;" 2>/dev/null || echo "?")
echo "==> Database ready. Users: $USER_COUNT"
