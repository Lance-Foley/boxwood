#!/bin/bash
set -e

echo "==> Checking dependencies..."

# Handle dependency drift: branches may add gems not in the base image.
# bundle_cache volume persists installs so this only runs once per new gem.
bundle check > /dev/null 2>&1 || {
  echo "==> Installing missing gems..."
  bundle install --jobs 4
}

# Handle node dependency drift (yarn install is a fast no-op when deps match)
yarn install --frozen-lockfile --check-files > /dev/null 2>&1 || yarn install

# Database initialization (only on first run, controlled by ws attach)
if [ "$DB_INIT" = "true" ]; then
  echo "==> Waiting for PostgreSQL..."
  until pg_isready -h db -U postgres -q; do
    sleep 1
  done

  echo "==> Restoring latest.dump..."
  # pg_restore returns non-zero on warnings (e.g. extension already exists) — this is OK
  # Uses -c --if-exists --clean to drop existing objects before restore
  pg_restore -h db -U postgres -d wescomapp -c -v --if-exists --clean --no-owner --no-privileges /dumps/latest.dump || true

  echo "==> Running migrations..."
  bundle exec rails db:migrate

  echo "==> Resetting dev passwords..."
  bundle exec rake update_encrypted_passwords

  echo "==> Database ready."
fi

# Hand off to the CMD (foreman, rails, bash, etc.)
exec "$@"
