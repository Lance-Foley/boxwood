#!/bin/sh
set -e

# First-run database setup is gated by DB_INIT, exactly like the real recipe.
# The no-DB fixture still ships db-init.sh so the entrypoint contract matches.
if [ "$DB_INIT" = "true" ]; then
  /usr/local/bin/db-init.sh
fi

# Hand off to the CMD (tail -f /dev/null by default).
exec "$@"
