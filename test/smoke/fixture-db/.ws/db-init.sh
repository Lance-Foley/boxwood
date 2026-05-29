#!/bin/sh
set -e

# Wait for the postgres service to accept connections, then drop the marker the
# healthcheck looks for. Mirrors the real recipe's pg_isready wait loop.
echo "==> Waiting for PostgreSQL..."
until pg_isready -h db -U postgres; do sleep 1; done

touch /tmp/.db_initialized
echo ready
