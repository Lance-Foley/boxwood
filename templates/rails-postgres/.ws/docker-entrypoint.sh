#!/bin/bash
set -e

# The worker container only runs background jobs and starts after the app is
# healthy — by which point the app has reconciled any dependency drift into the
# session's shared bundle_cache. So skip reconciliation entirely on the worker.
if [ "${WS_ROLE:-}" != "worker" ]; then
  echo "==> Checking dependencies..."

  # Dependency drift: branches may add gems not in the base image. The bundle_cache
  # volume persists installs so this only runs once per new gem.
  bundle check > /dev/null 2>&1 || {
    echo "==> Installing missing gems..."
    bundle install --jobs 4
  }

  # Node dependency drift (a fast no-op when deps already match).
  yarn install --frozen-lockfile --check-files > /dev/null 2>&1 || yarn install
fi

# First-run database setup (controlled by ws via DB_INIT).
# db-init.sh is the single source of truth, shared with `ws db-restore`.
if [ "$DB_INIT" = "true" ]; then
  /usr/local/bin/db-init.sh
fi

# Hand off to the CMD (foreman, rails solid_queue:start, bash, etc.)
exec "$@"
