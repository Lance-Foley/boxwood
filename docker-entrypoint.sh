#!/bin/bash
set -e

# The worker container only runs SolidQueue (pure Ruby) and starts after the app is
# healthy — by which point the app has already reconciled any dependency drift into
# the session's shared bundle_cache. So skip reconciliation entirely on the worker:
# it needs no node_modules and the gems are already installed.
if [ "${WS_ROLE:-}" != "worker" ]; then
  echo "==> Checking dependencies..."

  # Handle dependency drift: branches may add gems not in the base image.
  # bundle_cache volume persists installs so this only runs once per new gem.
  bundle check > /dev/null 2>&1 || {
    echo "==> Installing missing gems..."
    bundle install --jobs 4
  }

  # Handle node dependency drift (yarn install is a fast no-op when deps match)
  yarn install --frozen-lockfile --check-files > /dev/null 2>&1 || yarn install
fi

# Database initialization (only on first run, controlled by ws attach).
# db-init.sh is the single source of truth, shared with `ws db-restore`.
if [ "$DB_INIT" = "true" ]; then
  /usr/local/bin/db-init.sh
fi

# Hand off to the CMD (foreman, rails, bash, etc.)
exec "$@"
